//go:build darwin || linux || netbsd

package probe

import (
	"bytes"
	"context"
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
)

func bluetoothTestBuild(t *testing.T) string {
	t.Helper()
	path := os.Getenv("OXTORG_BLUETOOTH_TEST_BUILD")
	if path == "" {
		path = "../build"
	}
	path, err := filepath.Abs(path)
	if err != nil {
		t.Fatal(err)
	}
	return path
}
func bluetoothFixture(t *testing.T) (string, func(string, string, os.FileMode)) {
	t.Helper()
	directory, err := os.MkdirTemp("", "bt-native-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(directory) })
	write := func(name, source string, mode os.FileMode) {
		t.Helper()
		if err := os.WriteFile(filepath.Join(directory, name), []byte(source), mode); err != nil {
			t.Fatal(err)
		}
	}
	log := filepath.Join(directory, "commands")
	prefix := fmt.Sprintf("#!/bin/sh\nprintf '%%s\\n' \"$0 $*\" >> %q\n", log)
	write("btconfig", prefix+fmt.Sprintf("if [ -f %q ]; then /usr/bin/yes x | /usr/bin/head -c 70000; else printf 'btuart0: <UP,RUNNING>\\n'; fi\n", filepath.Join(directory, "flood")), 0700)
	write("oxtorg-bluetooth-admin", prefix+"if [ \"$1\" = state ]; then printf 'SSP=1 SC=1\\n'; fi\n", 0700)
	write("sdpquery", prefix+"printf 'Serial Port channel 2\\n'\n", 0700)
	write("bluetooth-a2dp", prefix+fmt.Sprintf("printf '%%s\\n' $$ > %q\nprintf 'Responded to command 7\\nStreaming 512 bytes\\n'\nexec /bin/cat > %q\n", filepath.Join(directory, "audio.pid"), filepath.Join(directory, "pcm")), 0700)
	return directory, write
}
func bluetoothCommand(t *testing.T, directory, source string, timeout int) *exec.Cmd {
	t.Helper()
	modules, _ := filepath.Abs("../lua")
	build, _ := filepath.Abs("../build")
	source = fmt.Sprintf("package.path=%q..'/?.lua;'..%q..'/?.lua;'..package.path\nlocal fixture=%q\n", modules, build, directory) + source
	entry := filepath.Join(directory, "probe.lua")
	if err := os.WriteFile(entry, []byte(source), 0600); err != nil {
		t.Fatal(err)
	}
	binaryPath := filepath.Join(bluetoothTestBuild(t), "bluetooth-native-test")
	return exec.Command(binaryPath, directory, entry, strconv.Itoa(timeout))
}
func bluetoothRun(t *testing.T, directory, source string, timeout int) string {
	t.Helper()
	command := bluetoothCommand(t, directory, source, timeout)
	var output bytes.Buffer
	command.Stdout, command.Stderr = &output, &output
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- command.Wait() }()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("Bluetooth native contract: %v\n%s", err, output.String())
		}
	case <-time.After(15 * time.Second):
		command.Process.Kill()
		<-done
		t.Fatalf("Bluetooth contract exceeded deadline\n%s", output.String())
	}
	return output.String()
}
func bluetoothPID(t *testing.T, path string) int {
	t.Helper()
	for until := time.Now().Add(3 * time.Second); time.Now().Before(until); {
		data, _ := os.ReadFile(path)
		pid, _ := strconv.Atoi(strings.TrimSpace(string(data)))
		if pid > 0 {
			return pid
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("Bluetooth child PID was not published")
	return 0
}
func bluetoothGone(t *testing.T, pid int) {
	t.Helper()
	for until := time.Now().Add(3 * time.Second); time.Now().Before(until); {
		if syscall.Kill(pid, 0) == syscall.ESRCH {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("Bluetooth child %d survived owner shutdown", pid)
}

func TestNativeBluetoothAdapterAndDiagnosticLifecycle(t *testing.T) {
	directory, _ := bluetoothFixture(t)
	listener, err := net.Listen("unix", filepath.Join(directory, "diagnostic.sock"))
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	var mutex sync.Mutex
	var requests int
	serverDone := make(chan struct{})
	go func() {
		defer close(serverDone)
		for index := 0; index < 2; index++ {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			query := make([]byte, 13)
			if _, err = io.ReadFull(conn, query); err != nil {
				conn.Close()
				return
			}
			mutex.Lock()
			requests++
			mutex.Unlock()
			if !bytes.Equal(query, []byte{2, 0x4b, 0x56, 0, 8, 0x35, 3, 0x19, 1, 0, 0, 1, 0}) {
				conn.Close()
				return
			}
			conn.Write([]byte{3, 0x4b, 0x56, 0, 9, 0, 1, 0, 1, 0, 0, 0, 1, 0})
			if index == 0 {
				time.Sleep(150 * time.Millisecond)
				conn.Close()
			} else {
				io.Copy(io.Discard, conn)
				conn.Close()
			}
		}
	}()
	output := bluetoothRun(t, directory, `local Bluetooth=require("bluetooth")
local connection=Bluetooth.connect({alias="bluetooth",module="bluetooth"},{env={VOICE_LANG="en",VOICE_KB_LIVE="/tmp/obd-fixture"}})
assert(connection:report().connected and connection:report().tools==8)
local byName={}
for _,tool in ipairs(connection:tools()) do byName[tool.name]=tool end
assert(byName["bluetooth.status"].class=="read" and not byName["bluetooth.status"].foreign)
assert(byName["bluetooth.discover"].foreign and byName["bluetooth.obd_read"].class=="read")
assert(byName["bluetooth.connect"].class=="write_local" and byName["bluetooth.connect"].foreign)
assert(byName["bluetooth.status"].source=="bluetooth")
assert(not pcall(byName["bluetooth.connect"].invoke,{address="; reboot"}))
assert(not pcall(byName["bluetooth.connect"].invoke,{address="00:11:22:33:44:55",mode="anything"}))
assert(not pcall(byName["bluetooth.power"].invoke,{}))
assert(not pcall(byName["bluetooth.obd_read"].invoke,{address="00:11:22:33:44:55",channel=31}))
assert(not io.open(fixture.."/commands"),"invalid arguments reached a command")
assert(byName["bluetooth.status"].invoke({}).output:find("SSP=1 SC=1",1,true))
assert(byName["bluetooth.services"].invoke({address="AA:BB:CC:DD:EE:FF"}).output:find("channel 2",1,true))
package.loaded["asenta.obd"]={read=function(options)
    assert(options.address=="aa:bb:cc:dd:ee:ff" and options.channel==2)
    assert(options.snapshotPath:match("^/tmp/obd%-fixture/obd%-%d%d%d%d%-%d%d%-%d%d_%d%d%d%d%d%d%.json$"))
    return {adapter="ELM327",values={rpm=700}}
end}
assert(byName["bluetooth.obd_read"].invoke({address="AA:BB:CC:DD:EE:FF",channel=2}).data.adapter=="ELM327")
local connected=byName["bluetooth.connect"].invoke({address="AA:BB:CC:DD:EE:FF",mode="legacy-pin"})
assert(connected.connectionLifetime=="until_disconnect" and connected.session.connected)
assert(connected.session.address=="aa:bb:cc:dd:ee:ff")
assert(not pcall(byName["bluetooth.connect"].invoke,{address="aa:bb:cc:dd:ee:ff"}),"replaced active peer")
local state
for i=1,50 do state=byName["bluetooth.status"].invoke({}).session; if not state.connected then break end end
assert(not state.connected,"peer loss stayed connected")
byName["bluetooth.disconnect"].invoke({})
assert(not byName["bluetooth.status"].invoke({}).session)
assert(byName["bluetooth.connect"].invoke({address="aa:bb:cc:dd:ee:ff"}).session.connected)
connection:close()
assert(not connection:report().connected)
assert(not pcall(connection.call,connection,"status",{}))
connection:close()
print("bluetooth-direct-ok")
`, 2000)
	if output != "bluetooth-direct-ok\n" {
		t.Fatal(output)
	}
	select {
	case <-serverDone:
	case <-time.After(time.Second):
		t.Fatal("adapter close kept diagnostic socket")
	}
	mutex.Lock()
	defer mutex.Unlock()
	if requests != 2 {
		t.Fatalf("SDP exchanges=%d", requests)
	}
}

func TestNativeBluetoothAudioAndBounds(t *testing.T) {
	directory, write := bluetoothFixture(t)
	output := bluetoothRun(t, directory, `local device <close> = require("asenta.bluetooth").open()
assert(not pcall(device.command,device,"anything"))
assert(not pcall(device.command,device,"pair","aa:bb:cc:dd:ee:ff","bad"))
assert(not pcall(device.command,device,"services","aa:bb:cc:dd:ee:ff\0bad"))
assert(not pcall(device.tone,device))
assert(device:connect("aa:bb:cc:dd:ee:ff","audio"))
assert(device:state().connected and device:state().audioPackets==1)
device:tone()
local file=assert(io.open(fixture.."/pcm","rb"));local size=file:seek("end");file:close()
-- A blocking main-thread command must not interrupt the audio worker.
for i=1,10 do device:command("status") end
file=assert(io.open(fixture.."/pcm","rb"));assert(file:seek("end")>size);file:close()
device:disconnect()
assert(not device:state())
assert(device:connect("aa:bb:cc:dd:ee:ff","audio"))
print("bluetooth-audio-ok")
`, 3000)
	if output != "bluetooth-audio-ok\n" {
		t.Fatal(output)
	}
	// The second child is closed by Lua's to-be-closed userdata at VM exit.
	bluetoothGone(t, bluetoothPID(t, filepath.Join(directory, "audio.pid")))
	// Capture the tone before the second connection truncates the PCM fixture.
	// A separate run avoids asserting a stale file descriptor's content.
	bluetoothRun(t, directory, `local device <close> = require("asenta.bluetooth").open();device:connect("aa:bb:cc:dd:ee:ff","audio");device:tone()`, 3000)
	pcm, err := os.ReadFile(filepath.Join(directory, "pcm"))
	if err != nil || len(pcm) < 88200*4 {
		t.Fatalf("PCM length=%d err=%v", len(pcm), err)
	}
	peak := 0
	for i := 0; i+1 < len(pcm); i += 2 {
		value := int(int16(binary.LittleEndian.Uint16(pcm[i:])))
		if value < 0 {
			value = -value
		}
		if value > peak {
			peak = value
		}
	}
	if peak < 11000 || peak > 12000 {
		t.Fatalf("quiet tone peak=%d", peak)
	}
	write("flood", "", 0600)
	bluetoothRun(t, directory, `local device <close> = require("asenta.bluetooth").open();local ok,why=pcall(device.command,device,"discover");assert(not ok and why:find("64 KiB",1,true),why)`, 3000)
	os.Remove(filepath.Join(directory, "flood"))
	write("sdpquery", fmt.Sprintf("#!/bin/sh\nprintf '%%s\\n' $$ > %q\nexec /bin/sleep 30\n", filepath.Join(directory, "stalled.pid")), 0700)
	bluetoothRun(t, directory, `local device <close> = require("asenta.bluetooth").open();local ok,why=pcall(device.command,device,"services","aa:bb:cc:dd:ee:ff");assert(not ok and why:lower():find("timed out",1,true),why)`, 1000)
	bluetoothGone(t, bluetoothPID(t, filepath.Join(directory, "stalled.pid")))
}

func TestNativeBluetoothSignalClosesAudio(t *testing.T) {
	directory, _ := bluetoothFixture(t)
	command := bluetoothCommand(t, directory, `local device=require("asenta.bluetooth").open();device:connect("aa:bb:cc:dd:ee:ff","audio");while true do device:command("status") end`, 3000)
	var output bytes.Buffer
	command.Stdout, command.Stderr = &output, &output
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	pid := bluetoothPID(t, filepath.Join(directory, "audio.pid"))
	command.Process.Signal(syscall.SIGTERM)
	done := make(chan error, 1)
	go func() { done <- command.Wait() }()
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		command.Process.Kill()
		<-done
		t.Fatal("signal shutdown stalled")
	}
	bluetoothGone(t, pid)
}

func TestNativeBluetoothAdminBoundary(t *testing.T) {
	directory, write := bluetoothFixture(t)
	binaryPath := filepath.Join(bluetoothTestBuild(t), "bluetooth-admin-test")
	write("pins.json", `{"aa:bb:cc:dd:ee:ff":"12\u0033\""}`, 0600)
	prefix := fmt.Sprintf("#!/bin/sh\nprintf '%%s\\n' \"$0 $*\" >> %q\n", filepath.Join(directory, "admin.commands"))
	write("bluetooth-control", prefix+"printf 'SSP=1 SC=1\\n'\n", 0700)
	write("bluetooth-pair", prefix+"exit 0\n", 0700)
	write("oxtorg_bluetooth", prefix+"exit 0\n", 0700)
	run := func(arguments ...string) (string, error) {
		t.Helper()
		args := append([]string{"--test-dir", directory, "--pin-file", filepath.Join(directory, "pins.json"), "--timeout-ms", "1000"}, arguments...)
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		command := exec.CommandContext(ctx, binaryPath, args...)
		input, err := command.StdinPipe()
		if err != nil {
			t.Fatal(err)
		}
		defer input.Close()
		out, err := command.CombinedOutput()
		return string(out), err
	}
	for _, args := range [][]string{{"state", "extra"}, {"power", "anything"}, {"pair", ";reboot", "bonded"}, {"pair", "aa:bb:cc:dd:ee:ff", "guess"}, {"exec", "/sbin/reboot"}} {
		if output, err := run(args...); err == nil {
			t.Fatalf("accepted %v: %s", args, output)
		}
	}
	if _, err := os.Stat(filepath.Join(directory, "admin.commands")); !os.IsNotExist(err) {
		t.Fatalf("invalid command executed: %v", err)
	}
	for _, args := range [][]string{{"state"}, {"power", "on"}, {"power", "off"}, {"pair", "aa:bb:cc:dd:ee:ff", "bonded"}, {"pair", "aa:bb:cc:dd:ee:ff", "just-works"}, {"pair", "aa:bb:cc:dd:ee:ff", "legacy-pin"}} {
		if output, err := run(args...); err != nil {
			t.Fatalf("admin %v: %v: %s", args, err, output)
		}
	}
	pin, err := os.ReadFile(filepath.Join(directory, "pin.received"))
	if err != nil || string(pin) != "123\"" {
		t.Fatalf("private PIN registration failed: %v", err)
	}
	info, err := os.Stat(filepath.Join(directory, "pin.received"))
	if err != nil || info.Mode().Perm() != 0600 {
		t.Fatal("test PIN escaped private permissions")
	}
	commands, _ := os.ReadFile(filepath.Join(directory, "admin.commands"))
	if strings.Contains(string(commands), "123") || strings.Contains(string(commands), "-k") {
		t.Fatal("PIN or persistent privileged connection escaped into argv")
	}
	os.Chmod(filepath.Join(directory, "pins.json"), 0644)
	if _, err := run("pair", "aa:bb:cc:dd:ee:ff", "legacy-pin"); err == nil {
		t.Fatal("accepted public PIN file")
	}
	os.Chmod(filepath.Join(directory, "pins.json"), 0600)
	for _, data := range []string{`{"aa:bb:cc:dd:ee:ff":1234}`, `{"aa:bb:cc:dd:ee:ff":"1234"} trailing`, `{"aa:bb:cc:dd:ee:ff":""}`} {
		write("pins.json", data, 0600)
		if _, err := run("pair", "aa:bb:cc:dd:ee:ff", "legacy-pin"); err == nil {
			t.Fatalf("accepted invalid private map %s", data)
		}
	}
	write("bluetooth-control", fmt.Sprintf("#!/bin/sh\nprintf '%%s\\n' $$ > %q\nexec /bin/sleep 30\n", filepath.Join(directory, "admin.pid")), 0700)
	if _, err := run("state"); err == nil {
		t.Fatal("helper ignored its own command deadline")
	}
	bluetoothGone(t, bluetoothPID(t, filepath.Join(directory, "admin.pid")))
	os.Remove(filepath.Join(directory, "admin.pid"))
	command := exec.Command(binaryPath, "--test-dir", directory, "--pin-file", filepath.Join(directory, "pins.json"), "state")
	input, err := command.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	pid := bluetoothPID(t, filepath.Join(directory, "admin.pid"))
	input.Close()
	done := make(chan error, 1)
	go func() { done <- command.Wait() }()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		command.Process.Kill()
		<-done
		t.Fatal("admin ignored caller loss")
	}
	bluetoothGone(t, pid)
}

func TestNativeBluetoothAdminCancellation(t *testing.T) {
	directory, write := bluetoothFixture(t)
	binaryPath := filepath.Join(bluetoothTestBuild(t), "bluetooth-admin-test")
	write("oxtorg-bluetooth-admin", fmt.Sprintf("#!/bin/sh\nexec %q --test-dir %q --pin-file %q \"$@\"\n", binaryPath, directory, filepath.Join(directory, "pins.json")), 0700)
	write("bluetooth-control", fmt.Sprintf("#!/bin/sh\nprintf '%%s\\n' $$ > %q\nexec /bin/sleep 30\n", filepath.Join(directory, "admin.pid")), 0700)
	bluetoothRun(t, directory, `local device <close> = require("asenta.bluetooth").open();local ok,why=pcall(device.command,device,"state");assert(not ok and why:lower():find("timed out",1,true),why)`, 1000)
	bluetoothGone(t, bluetoothPID(t, filepath.Join(directory, "admin.pid")))
	os.Remove(filepath.Join(directory, "admin.pid"))
	command := bluetoothCommand(t, directory, `local device=require("asenta.bluetooth").open();device:command("state")`, 10000)
	var output bytes.Buffer
	command.Stdout, command.Stderr = &output, &output
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	pid := bluetoothPID(t, filepath.Join(directory, "admin.pid"))
	command.Process.Signal(syscall.SIGTERM)
	done := make(chan error, 1)
	go func() { done <- command.Wait() }()
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		command.Process.Kill()
		<-done
		t.Fatal("native caller shutdown kept its admin child")
	}
	bluetoothGone(t, pid)
}
