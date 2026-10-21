CC = cc
PKG_CONFIG = pkg-config
TARGET_OS != uname -s
GO = go
BUILD_DIR = build
LUA_PACKAGE = lua5.5
LUA_CFLAGS != $(PKG_CONFIG) --cflags $(LUA_PACKAGE) 2>/dev/null
LUA_LIBS != $(PKG_CONFIG) --libs $(LUA_PACKAGE) 2>/dev/null
CURL_CFLAGS != $(PKG_CONFIG) --cflags libcurl
CURL_LIBS != $(PKG_CONFIG) --libs libcurl
CRYPTO_CFLAGS != case "$(TARGET_OS)" in NetBSD|Darwin) ;; *) $(PKG_CONFIG) --cflags libcrypto 2>/dev/null;; esac
CRYPTO_LIBS != case "$(TARGET_OS)" in NetBSD|Darwin) ;; *) $(PKG_CONFIG) --libs libcrypto 2>/dev/null || echo -lcrypto;; esac
CFLAGS = -Os -std=c99 -Wall -Wextra -Werror
NATIVE_LIBS != test "$(TARGET_OS)" != NetBSD || echo -lprop -lbluetooth
NATIVE_BLUETOOTH_LIBS != test "$(TARGET_OS)" != NetBSD || echo -lbluetooth
SOURCES = src/main.c src/service.c src/http.c src/fs.c src/process.c src/equipment.c src/bluetooth.c src/obd.c

all: $(BUILD_DIR)/agent-lua $(BUILD_DIR)/bluetooth-admin

$(BUILD_DIR)/agent-lua: $(SOURCES) src/host.h
	mkdir -p $(BUILD_DIR)
	$(CC) $(CPPFLAGS) $(CFLAGS) $(LUA_CFLAGS) $(CURL_CFLAGS) $(CRYPTO_CFLAGS) $(SOURCES) $(LDFLAGS) $(LUA_LIBS) $(CURL_LIBS) $(CRYPTO_LIBS) $(NATIVE_LIBS) -lpthread -lm -o $@

$(BUILD_DIR)/bluetooth-admin: src/bluetooth-admin.c
	mkdir -p $(BUILD_DIR)
	$(CC) $(CPPFLAGS) $(CFLAGS) src/bluetooth-admin.c $(LDFLAGS) $(NATIVE_BLUETOOTH_LIBS) -o $@

$(BUILD_DIR)/bluetooth-native-test: src/bluetooth.c src/host.h
	mkdir -p $(BUILD_DIR)
	$(CC) $(CPPFLAGS) $(CFLAGS) $(LUA_CFLAGS) -DBLUETOOTH_NATIVE_TEST src/bluetooth.c $(LDFLAGS) $(LUA_LIBS) $(NATIVE_BLUETOOTH_LIBS) -lpthread -lm -o $@

$(BUILD_DIR)/bluetooth-admin-test: src/bluetooth-admin.c
	mkdir -p $(BUILD_DIR)
	$(CC) $(CPPFLAGS) $(CFLAGS) -DBLUETOOTH_ADMIN_TEST src/bluetooth-admin.c $(LDFLAGS) $(NATIVE_BLUETOOTH_LIBS) -o $@

.PHONY: all test clean package
package:
	./build.sh

test: all $(BUILD_DIR)/bluetooth-native-test $(BUILD_DIR)/bluetooth-admin-test
	cd tests && $(GO) test -count=1 -v .

clean:
	rm -f $(BUILD_DIR)/agent-lua $(BUILD_DIR)/bluetooth-admin $(BUILD_DIR)/bluetooth-native-test $(BUILD_DIR)/bluetooth-admin-test
