BIN      := dialspace
SRC      := dialspace.swift
PREFIX   := $(HOME)/.local
BINDIR   := $(PREFIX)/bin
LOGDIR   := $(PREFIX)/share
PLIST    := $(HOME)/Library/LaunchAgents/com.skyler.dialspace.plist
LABEL    := com.skyler.dialspace
FRAMEWORKS := -framework IOKit -framework CoreGraphics -framework CoreFoundation -framework ApplicationServices

.PHONY: build install uninstall reload logs status clean

build:
	swiftc -O $(SRC) -o $(BIN) $(FRAMEWORKS)

install: build
	mkdir -p $(BINDIR) $(LOGDIR) $(HOME)/Library/LaunchAgents
	cp $(BIN) $(BINDIR)/$(BIN)
	chmod +x $(BINDIR)/$(BIN)
	sed -e 's#@BIN@#$(BINDIR)/$(BIN)#g' -e 's#@LOG@#$(LOGDIR)/dialspace.log#g' \
		com.skyler.dialspace.plist.in > $(PLIST)
	plutil -lint $(PLIST)
	-launchctl bootout gui/$$(id -u)/$(LABEL) 2>/dev/null
	launchctl bootstrap gui/$$(id -u) $(PLIST)
	@echo ""
	@echo ">>> 已安装并启动。若日志报「创建事件 tap 失败」,去"
	@echo ">>> 系统设置 > 隐私与安全性 > 辅助功能,添加并勾选: $(BINDIR)/$(BIN)"

# 改完源码后重新编译、替换、重启服务(注意:重编后需重新授权辅助功能)
reload: build
	cp $(BIN) $(BINDIR)/$(BIN)
	launchctl kickstart -k gui/$$(id -u)/$(LABEL)
	@echo ">>> 已重启。如果切屏失效,重新授权辅助功能。"

uninstall:
	-launchctl bootout gui/$$(id -u)/$(LABEL) 2>/dev/null
	rm -f $(PLIST) $(BINDIR)/$(BIN)
	@echo ">>> 已卸载(日志保留在 $(LOGDIR)/dialspace.log)"

status:
	launchctl print gui/$$(id -u)/$(LABEL) | grep -E "state =|pid =" | head -3

logs:
	tail -f $(LOGDIR)/dialspace.log

clean:
	rm -f $(BIN)
