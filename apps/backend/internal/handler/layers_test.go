package handler_test

import (
	"go/ast"
	"go/parser"
	"go/token"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// Тест-сторож слоёв бэкенда (ADHOC-71, долг 38; правило dev.md §2).
//
// Что: разбирает исходники handler, repository и service и падает, если правило слоёв снова
// нарушено.
// Зачем: долг 38 копился месяц потому, что новый код брал в образец соседний старый. Сторож
// ловит нарушение на PR, а не на следующей уборке.
// Как: только синтаксис (go/parser), без сборки и базы. Проверки:
//   - обработчик не импортирует repository;
//   - обработчик не держит конкретный *service.XxxService - только узкий интерфейс в своём файле.
//     Исключение - router.go: это место сборки зависимостей, конкретные сервисы ему положены;
//   - ошибки-сигналы (var ErrXxx = errors.New(…)) не объявляются в repository и service - их
//     место в model.

// parseDir разбирает исходники каталога без тестов.
func parseDir(t *testing.T, dir string) map[string]*ast.File {
	t.Helper()
	paths, err := filepath.Glob(filepath.Join(dir, "*.go"))
	if err != nil {
		t.Fatal(err)
	}
	fset := token.NewFileSet()
	out := map[string]*ast.File{}
	for _, p := range paths {
		if strings.HasSuffix(p, "_test.go") {
			continue
		}
		f, err := parser.ParseFile(fset, p, nil, 0)
		if err != nil {
			t.Fatalf("разобрать %s: %v", p, err)
		}
		out[filepath.Base(p)] = f
	}
	if len(out) == 0 {
		t.Fatalf("в %s нет исходников - сторож смотрит не туда", dir)
	}
	return out
}

// TestLayers_handlerDependsOnInterfaces - обработчики без repository и без *service.XxxService.
func TestLayers_handlerDependsOnInterfaces(t *testing.T) {
	for name, f := range parseDir(t, ".") {
		for _, imp := range f.Imports {
			if path, _ := strconv.Unquote(imp.Path.Value); path == "craftwms/internal/repository" {
				t.Errorf("%s импортирует repository: ошибки - из model, данные - через сервис", name)
			}
		}
		if name == "router.go" {
			continue
		}
		ast.Inspect(f, func(n ast.Node) bool {
			star, ok := n.(*ast.StarExpr)
			if !ok {
				return true
			}
			sel, ok := star.X.(*ast.SelectorExpr)
			if !ok {
				return true
			}
			if pkg, ok := sel.X.(*ast.Ident); ok && pkg.Name == "service" && strings.HasSuffix(sel.Sel.Name, "Service") {
				t.Errorf("%s держит *service.%s: объявите в файле обработчика узкий интерфейс", name, sel.Sel.Name)
			}
			return true
		})
	}
}

// TestLayers_signalErrorsInModel - в repository и service нет var ErrXxx = errors.New(…).
func TestLayers_signalErrorsInModel(t *testing.T) {
	for _, dir := range []string{"../repository", "../service"} {
		for name, f := range parseDir(t, dir) {
			for _, decl := range f.Decls {
				gd, ok := decl.(*ast.GenDecl)
				if !ok || gd.Tok != token.VAR {
					continue
				}
				for _, spec := range gd.Specs {
					vs := spec.(*ast.ValueSpec)
					for i, id := range vs.Names {
						if !strings.HasPrefix(id.Name, "Err") || i >= len(vs.Values) {
							continue
						}
						call, ok := vs.Values[i].(*ast.CallExpr)
						if !ok {
							continue
						}
						if sel, ok := call.Fun.(*ast.SelectorExpr); ok && sel.Sel.Name == "New" {
							if pkg, ok := sel.X.(*ast.Ident); ok && pkg.Name == "errors" {
								t.Errorf("%s/%s объявляет %s: ошибке-сигналу место в model", filepath.Base(dir), name, id.Name)
							}
						}
					}
				}
			}
		}
	}
}
