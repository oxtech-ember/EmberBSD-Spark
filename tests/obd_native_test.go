//go:build darwin || linux || netbsd

package probe

import (
	"bufio"
	"bytes"
	"context"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"runtime"
	"strings"
	"syscall"
	"testing"
	"time"
)

// Only this executable exposes an inherited fixture socket. The deployed
// module has no fd, arbitrary-command or simulated-response API.
const nativeOBDHarness = `
#include "obd.c"
#include <lualib.h>
static int fixture_read(lua_State *L) { return read_session(L, 3); }
static int forbidden(lua_State *L) {
    struct obd_link link = {.fd = -1};
    command(L, &link, "04", 1);
    return 0;
}
int main(int argc, char **argv) {
    lua_State *L = luaL_newstate();
    if (!L) return 1;
    luaL_openlibs(L);
    luaL_requiref(L, "asenta.fs", luaopen_asenta_fs, 0); lua_pop(L, 1);
    luaL_requiref(L, "asenta.obd", luaopen_asenta_obd, 0);
    lua_pushcfunction(L, fixture_read); lua_setfield(L, -2, "read");
    lua_pushcfunction(L, forbidden); lua_setfield(L, -2, "forbidden");
    lua_pop(L, 1);
    lua_newtable(L);
    for (int i = 1; i < argc; ++i) { lua_pushstring(L, argv[i]); lua_rawseti(L, -2, i - 1); }
    lua_setglobal(L, "arg");
    int code = luaL_dofile(L, argv[1]);
    if (code) fprintf(stderr, "%s\n", lua_tostring(L, -1));
    lua_close(L);
    return code != LUA_OK;
}
`

const nativeOBDScript = `
package.path = arg[1] .. "/?.lua;" .. package.path
local obd, json = require("asenta.obd"), require("json")
local allowed, why = pcall(obd.forbidden)
assert(not allowed and why:find("obd_command_not_read_only", 1, true))
local options = {address="01:23:45:67:89:ba", channel=2}
if arg[3] ~= "default-path" then options.snapshotPath = arg[2] end
if arg[3] == "labels" then options.labels = {["Engine speed, rpm"]="RPM label"} end
if arg[3] == "invalid-channel" then options.channel=31 end
local ok, result = pcall(obd.read, options)
print(json.encode({ok=ok, result=result}))
`

func compileNativeOBD(t *testing.T, directory string) string {
	t.Helper()
	source := filepath.Join(directory, "obd-harness.c")
	if err := os.WriteFile(source, []byte(nativeOBDHarness), 0600); err != nil {
		t.Fatal(err)
	}
	src, _ := filepath.Abs("../src")
	binary := filepath.Join(directory, "obd-harness")
	flags := []string{"-Os", "-std=c99", "-Wall", "-Wextra", "-Werror", "-I" + src}
	if configured := os.Getenv("OBD_TEST_CFLAGS"); configured != "" {
		flags = append(flags, strings.Fields(configured)...)
	} else if runtime.GOOS != "netbsd" {
		out, err := exec.Command("pkg-config", "--cflags", "lua5.5", "libcrypto").Output()
		if err != nil {
			t.Fatalf("native OBD tests need Lua 5.5 headers; set OBD_TEST_CFLAGS and OBD_TEST_LIBS: %v", err)
		}
		flags = append(flags, strings.Fields(string(out))...)
	}
	flags = append(flags, source, filepath.Join(src, "fs.c"), "-o", binary)
	if configured := os.Getenv("OBD_TEST_LIBS"); configured != "" {
		flags = append(flags, strings.Fields(configured)...)
	} else if runtime.GOOS == "netbsd" {
		flags = append(flags, "-llua", "-lbluetooth")
	} else {
		out, err := exec.Command("pkg-config", "--libs", "lua5.5", "libcrypto").Output()
		if err != nil {
			t.Fatal(err)
		}
		flags = append(flags, strings.Fields(string(out))...)
	}
	compiler := os.Getenv("CC")
	if compiler == "" {
		compiler = "cc"
	}
	if out, err := exec.Command(compiler, flags...).CombinedOutput(); err != nil {
		t.Fatalf("compile native OBD fixture: %v\n%s", err, out)
	}
	return binary
}

func TestNativeOBD(t *testing.T) {
	// Keep fixture endpoints above the child's fd 3 even when run alone. An
	// inherited peer would otherwise be accidentally closed by fd remapping.
	for range 4 {
		guard, err := os.Open(os.DevNull)
		if err != nil {
			t.Fatal(err)
		}
		defer guard.Close()
	}
	directory := t.TempDir()
	binary := compileNativeOBD(t, directory)
	entry := filepath.Join(directory, "obd.lua")
	if err := os.WriteFile(entry, []byte(nativeOBDScript), 0600); err != nil {
		t.Fatal(err)
	}
	modules, _ := filepath.Abs("../lua")
	queries := []string{"ATZ", "ATE0", "ATL0", "ATS1", "ATH0", "ATSP0", "ATI", "ATRV", "0100", "ATDP",
		"010C", "010D", "0105", "010F", "0104", "0111", "012F", "0142", "011F", "0121", "0131", "0101", "03", "07", "0902"}
	vin := "1HGCM82633A004352"
	var vinBytes []string
	for _, value := range []byte(vin) {
		vinBytes = append(vinBytes, hex.EncodeToString([]byte{value}))
	}
	responses := map[string]string{
		"ATI": "ELM327 v1.5", "ATRV": "12.6V", "0100": "SEARCHING...\r41 00 FF FF FF FF",
		"ATDP": "AUTO, ISO 15765-4 (CAN 11/500)", "010C": "010C\r41 0C 0A F0",
		"010D": "41 0D 2A", "0105": "41 05 7B", "010F": "41 0F 32",
		"0104": "41 04 80", "0111": "41 11 FF", "012F": "41 2F 00",
		"0142": "41 42 30 39", "011F": "41 1F 00 7B", "0121": "41 21 01 00", "0131": "41 31 01 F4",
		"0101": "41 01 81 00 00 00", "03": "43 02 01 33 00 00", "07": "47 01 C1 23",
		"0902": "49 02 01 " + strings.Join(vinBytes, " "),
	}
	for _, scenario := range []string{"values", "labels", "non-ascii", "default-path", "no-faults", "unknown", "vehicle-missing", "vehicle-malformed", "closed", "oversize", "timeout", "invalid-channel", "save-failure"} {
		t.Run(scenario, func(t *testing.T) {
			base := t.TempDir()
			snapshot := filepath.Join(base, "snapshot.json")
			if err := os.WriteFile(snapshot, []byte(`{"old":true}`), 0600); err != nil {
				t.Fatal(err)
			}
			if scenario == "save-failure" {
				snapshot += "/child.json"
			}
			fds, err := syscall.Socketpair(syscall.AF_UNIX, syscall.SOCK_STREAM, 0)
			if err != nil {
				t.Fatal(err)
			}
			syscall.CloseOnExec(fds[0])
			syscall.CloseOnExec(fds[1])
			peer, child := os.NewFile(uintptr(fds[0]), "peer"), os.NewFile(uintptr(fds[1]), "child")
			defer peer.Close()
			defer child.Close()
			ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
			defer cancel()
			cmd := exec.CommandContext(ctx, binary, entry, modules, snapshot, scenario)
			cmd.ExtraFiles = []*os.File{child}
			cmd.Env = append(os.Environ(), "VOICE_KB_LIVE="+filepath.Join(base, "live"))
			var output bytes.Buffer
			cmd.Stdout, cmd.Stderr = &output, &output
			if err := cmd.Start(); err != nil {
				t.Fatal(err)
			}
			child.Close()
			type observed struct {
				queries []string
				err     error
			}
			finished := make(chan observed, 1)
			go func() {
				var seen []string
				reader := bufio.NewReader(peer)
				for {
					query, err := reader.ReadString('\r')
					if err != nil {
						if err == io.EOF {
							err = nil
						}
						finished <- observed{seen, err}
						return
					}
					query = strings.TrimSuffix(query, "\r")
					seen = append(seen, query)
					if scenario == "closed" {
						peer.Close()
						finished <- observed{seen, nil}
						return
					}
					if scenario == "timeout" {
						continue
					}
					response, known := responses[query]
					if !known {
						response = "OK"
					}
					if scenario == "oversize" {
						response = strings.Repeat("F", 16385)
					}
					if scenario == "vehicle-missing" && query == "0100" {
						response = "UNABLE TO CONNECT"
					}
					if scenario == "vehicle-malformed" && query == "0100" {
						response = "?"
					}
					if scenario == "non-ascii" && query == "ATI" {
						response = "ELM327 v1.5\xff"
					}
					if scenario == "unknown" && !strings.HasPrefix(query, "AT") && query != "0100" {
						response = "NO DATA"
						if query == "010C" {
							response = "41 0C 01"
						} else if query == "03" {
							response = "?"
						}
					}
					if scenario == "no-faults" {
						switch query {
						case "0101":
							response = "41 01 00 00 00 00"
						case "03":
							response = "43 00 00"
						case "07":
							response = "47 00"
						}
					}
					// Split responses across reads, including a separate prompt.
					if _, err := io.WriteString(peer, response+"\r"); err != nil {
						finished <- observed{seen, nil}
						return
					}
					if _, err := io.WriteString(peer, ">"); err != nil {
						finished <- observed{seen, nil}
						return
					}
				}
			}()
			started := time.Now()
			if err := cmd.Wait(); err != nil {
				t.Fatalf("native OBD fixture: %v\n%s", err, output.String())
			}
			seen := <-finished
			if seen.err != nil {
				t.Fatal(seen.err)
			}
			var answer struct {
				OK     bool `json:"ok"`
				Result any  `json:"result"`
			}
			if err := json.Unmarshal(output.Bytes(), &answer); err != nil {
				t.Fatalf("invalid fixture output: %v %s", err, output.String())
			}
			wantError := map[string]string{"vehicle-missing": "obd_vehicle_did_not_answer", "vehicle-malformed": "obd_vehicle_did_not_answer", "closed": "obd_rfcomm_connection_closed", "oversize": "obd_response_too_long", "timeout": "obd_adapter_response_timeout", "invalid-channel": "obd_invalid_bluetooth_target", "save-failure": "obd_snapshot_failed"}[scenario]
			if wantError != "" {
				if answer.OK || !strings.Contains(fmt.Sprint(answer.Result), wantError) {
					t.Fatalf("wrong failure: %#v", answer)
				}
				if scenario == "timeout" && time.Since(started) > 12*time.Second {
					t.Fatal("response deadline was not bounded")
				}
				if scenario == "invalid-channel" {
					if len(seen.queries) != 0 {
						t.Fatalf("invalid target sent commands: %v", seen.queries)
					}
					return
				}
				if scenario == "save-failure" {
					body, _ := os.ReadFile(filepath.Dir(snapshot))
					if string(body) != `{"old":true}` {
						t.Fatalf("failed save damaged previous file: %s", body)
					}
					return
				}
			} else if !answer.OK || !reflect.DeepEqual(seen.queries, queries) {
				t.Fatalf("incomplete read: %#v commands=%v", answer, seen.queries)
			}
			if scenario == "default-path" {
				matches, err := filepath.Glob(filepath.Join(base, "live", "obd-????-??-??_??????.json"))
				if err != nil || len(matches) != 1 {
					t.Fatalf("missing timestamped snapshot: %v %v", matches, err)
				}
				snapshot = matches[0]
			}
			body, err := os.ReadFile(snapshot)
			if err != nil {
				t.Fatal(err)
			}
			var saved map[string]any
			if err := json.Unmarshal(body, &saved); err != nil {
				t.Fatal(err)
			}
			info, _ := os.Stat(snapshot)
			if info.Mode().Perm() != 0600 {
				t.Fatalf("snapshot is not private: %s", info.Mode())
			}
			values, ok := saved["values"].(map[string]any)
			if !ok || saved["adapter_addr"] != "01:23:45:67:89:ba" || saved["time"] == nil {
				t.Fatalf("snapshot contract lost: %s", body)
			}
			if wantError != "" {
				if !strings.Contains(fmt.Sprint(saved["error"]), wantError) || len(values) != 0 || saved["adapter"] != nil {
					t.Fatalf("failure saved partial success: %s", body)
				}
				return
			}
			if !reflect.DeepEqual(saved, answer.Result) {
				t.Fatalf("snapshot differs from return value: %s versus %#v", body, answer.Result)
			}
			if scenario == "unknown" {
				if len(values) != 11 || saved["check_engine"] != nil || saved["dtc_count"] != nil || saved["vin"] != nil {
					t.Fatalf("unknown data became healthy: %s", body)
				}
				for name, value := range values {
					if value != nil {
						t.Fatalf("unknown %s became %v", name, value)
					}
				}
				if len(saved["dtc_stored"].([]any)) != 0 || len(saved["dtc_pending"].([]any)) != 0 {
					t.Fatalf("malformed DTC response invented a code: %s", body)
				}
				return
			}
			engineKey := "Engine speed, rpm"
			if scenario == "labels" {
				engineKey = "RPM label"
			}
			adapter := "ELM327 v1.5"
			if scenario == "non-ascii" {
				adapter += "\ufffd"
			}
			wantValues := map[string]any{engineKey: float64(700), "Speed, km/h": float64(42), "Coolant temperature, C": float64(83), "Intake air temperature, C": float64(10), "Engine load, percent": 50.2, "Throttle position, percent": float64(100), "Fuel level, percent": float64(0), "ECU voltage, V": 12.345, "Time since start, s": float64(123), "Distance with Check Engine, km": float64(256), "Distance since DTC reset, km": float64(500)}
			if !reflect.DeepEqual(values, wantValues) || saved["vin"] != vin || saved["adapter"] != adapter || saved["battery_v"] != "12.6V" || saved["protocol"] != responses["ATDP"] {
				t.Fatalf("decoded values changed: %s", body)
			}
			if scenario == "no-faults" {
				if saved["check_engine"] != false || saved["dtc_count"] != float64(0) || len(saved["dtc_stored"].([]any)) != 0 || len(saved["dtc_pending"].([]any)) != 0 {
					t.Fatalf("valid no-fault response changed: %s", body)
				}
			} else if saved["check_engine"] != true || saved["dtc_count"] != float64(1) || !reflect.DeepEqual(saved["dtc_stored"], []any{"P0133"}) || !reflect.DeepEqual(saved["dtc_pending"], []any{"U0123"}) {
				t.Fatalf("decoded DTC changed: %s", body)
			}
		})
	}
}
