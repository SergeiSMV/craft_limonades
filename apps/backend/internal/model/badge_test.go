package model

import "testing"

// ADHOC-65: уровень печати бейджей — самый широкий из отмеченных, «Администратор» — всех.
func TestBadgeScope(t *testing.T) {
	cases := []struct {
		access             Access
		scope              BadgeScope
		self, other, admin bool // можно ли: свой, чужой, администратора
	}{
		{Access{}, BadgeScopeNone, false, false, false},
		{Access{Rights: []string{RightTSDBadgesOwn}}, BadgeScopeOwn, true, false, false},
		{Access{Rights: []string{RightTSDBadgesOwn, RightTSDBadgesStaff}}, BadgeScopeStaff, true, true, false},
		{Access{Rights: []string{RightTSDBadgesAll}}, BadgeScopeAll, true, true, true},
		{Access{System: true}, BadgeScopeAll, true, true, true},
	}
	for i, c := range cases {
		s := BadgeScopeOf(c.access)
		if s != c.scope || s.Allows(true, false) != c.self || s.Allows(false, false) != c.other ||
			s.Allows(false, true) != c.admin {
			t.Errorf("случай %d: уровень %d", i, s)
		}
	}
}
