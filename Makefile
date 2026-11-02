CC = cc
PKG_CONFIG = pkg-config
TARGET_OS != uname -s
GO = go
BUILD_DIR = build
LUA_PACKAGE = lua-5.5
LUA_CFLAGS != $(PKG_CONFIG) --cflags $(LUA_PACKAGE) 2>/dev/null
PKG_CONFIG_STATIC?=no
PKG_CONFIG_STATIC_FLAG != test "$(PKG_CONFIG_STATIC)" != yes || echo --static
LUA_LIBS != $(PKG_CONFIG) $(PKG_CONFIG_STATIC_FLAG) --libs $(LUA_PACKAGE) 2>/dev/null
CURL_CFLAGS != $(PKG_CONFIG) --cflags libcurl
CURL_LIBS != $(PKG_CONFIG) $(PKG_CONFIG_STATIC_FLAG) --libs libcurl
CRYPTO_CFLAGS != case "$(TARGET_OS)" in NetBSD|Darwin) ;; *) $(PKG_CONFIG) --cflags libcrypto 2>/dev/null;; esac
CRYPTO_LIBS != case "$(TARGET_OS)" in NetBSD|Darwin) ;; *) $(PKG_CONFIG) $(PKG_CONFIG_STATIC_FLAG) --libs libcrypto 2>/dev/null || echo -lcrypto;; esac
CFLAGS = -Os -std=c99 -Wall -Wextra -Werror
ENABLE_BLUETOOTH?=yes
NATIVE_LIBS != test "$(TARGET_OS)" != NetBSD || echo -lprop
NATIVE_BLUETOOTH_LIBS != test "$(TARGET_OS)" != NetBSD || test "$(ENABLE_BLUETOOTH)" = no || echo -lbluetooth
BLUETOOTH_SOURCES != test "$(ENABLE_BLUETOOTH)" = no || echo "src/bluetooth.c src/obd.c"
BLUETOOTH_TARGETS != test "$(ENABLE_BLUETOOTH)" = no || echo "$(BUILD_DIR)/bluetooth-admin"
BLUETOOTH_CPPFLAGS != test "$(ENABLE_BLUETOOTH)" != no || echo -DSPARK_NO_BLUETOOTH
SOURCES = src/main.c src/service.c src/http.c src/fs.c src/process.c src/equipment.c $(BLUETOOTH_SOURCES)

all: $(BUILD_DIR)/agent-lua $(BLUETOOTH_TARGETS)

$(BUILD_DIR)/agent-lua: $(SOURCES) src/host.h
	mkdir -p $(BUILD_DIR)
	$(CC) $(CPPFLAGS) $(BLUETOOTH_CPPFLAGS) $(CFLAGS) $(LUA_CFLAGS) $(CURL_CFLAGS) $(CRYPTO_CFLAGS) $(SOURCES) $(LDFLAGS) $(LUA_LIBS) $(CURL_LIBS) $(CRYPTO_LIBS) $(NATIVE_LIBS) $(NATIVE_BLUETOOTH_LIBS) -lpthread -lm -o $@

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
