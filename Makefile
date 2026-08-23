# Crux 로컬 패키징.
#
#   make dmg   개인 Apple Development로 서명한 앱을 DMG로 만든다
#   make app   .xcbuild/Crux.app 번들만 만든다
#
# SKIP_BUILD=1, CODESIGN_IDENTITY, CONFIG 는 스크립트에 그대로 전달된다.

.PHONY: help app dmg

help:
	@echo "make dmg   서명된 Crux.app + Applications 바로가기가 들어 있는 DMG"
	@echo "make app   .xcbuild/Crux.app 번들"

app:
	./scripts/make_app.sh

dmg:
	./scripts/make_dmg.sh
