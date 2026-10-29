# Туннель стенда к подписанту Честного знака на проде (ADHOC-54): только ssh-клиент.
FROM alpine:3.20
RUN apk add --no-cache openssh-client
