package probe

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestHTTPStreamsRequestJSONWithBoundedReads(t *testing.T) {
	var mu sync.Mutex
	calls := map[string]int{}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		calls[r.URL.Path]++
		attempt := calls[r.URL.Path]
		mu.Unlock()
		w.Header().Set("X-Upload-Result", "fixture")
		if r.URL.Path == "/upload" {
			if r.Method != "POST" || r.ContentLength <= 10*1024*1024 || len(r.TransferEncoding) != 0 ||
				r.Header.Get("Content-Type") != "application/json" || r.Header.Get("X-Fixture") != "stream" ||
				r.Header.Get("Authorization") != "Bearer fixture-header" {
				t.Errorf("streamed request headers: method=%s length=%d headers=%v", r.Method, r.ContentLength, r.Header)
				http.Error(w, "headers differ", 400)
				return
			}
			counter := &httpStreamCounter{Reader: r.Body}
			if err := checkHTTPStreamPayload(counter); err != nil {
				t.Error(err)
				http.Error(w, "payload differs", 400)
				return
			}
			if counter.bytes != r.ContentLength {
				t.Errorf("received %d bytes, declared %d", counter.bytes, r.ContentLength)
			}
			io.WriteString(w, `{"ok":true,"files":640}`)
			return
		}
		body, err := io.ReadAll(r.Body)
		switch r.URL.Path {
		case "/error", "/retry":
			if err != nil || string(body) != `{"small":true}` || r.ContentLength != int64(len(body)) {
				t.Errorf("small streamed body at %s: %q, %v", r.URL.Path, body, err)
			}
			if r.URL.Path == "/error" || attempt == 1 {
				w.WriteHeader(503)
				io.WriteString(w, `{"reason":"fixture_rejected","error":"expected rejection"}`)
			} else {
				io.WriteString(w, `{"ok":true}`)
			}
		case "/raw":
			if r.Method != "PATCH" || err != nil || string(body) != `{"raw":true}` ||
				r.Header.Get("Content-Type") != "application/custom+json" {
				t.Errorf("raw body changed: %s %q %v", r.Method, body, err)
			}
			io.WriteString(w, `{"ok":true}`)
		case "/empty":
			if err != nil || len(body) != 0 || r.ContentLength != 0 {
				t.Errorf("empty upload: %q %v", body, err)
			}
			io.WriteString(w, `{"ok":true}`)
		default:
			// Invalid readers abort the request, so a short body is expected.
			w.WriteHeader(400)
		}
	}))
	defer server.Close()
	directory := t.TempDir()
	script := filepath.Join(directory, "http-stream.lua")
	if err := os.WriteFile(script, []byte(httpStreamScenario), 0600); err != nil {
		t.Fatal(err)
	}
	modules, err := filepath.Abs("../lua")
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "../build/agent-lua", script, modules, server.URL)
	if output, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("native streamed upload: %v\n%s", err, output)
	}
	mu.Lock()
	defer mu.Unlock()
	if calls["/upload"] != 1 || calls["/error"] != 1 || calls["/retry"] != 2 || calls["/raw"] != 1 || calls["/empty"] != 1 {
		t.Fatalf("request/retry counts: %v", calls)
	}
	if calls["/zero-extra"] != 0 || calls["/bound"] != 0 {
		t.Fatalf("invalid body declaration reached the server: %v", calls)
	}
}

type httpStreamCounter struct {
	io.Reader
	bytes int64
}

func (r *httpStreamCounter) Read(p []byte) (int, error) {
	n, err := r.Reader.Read(p)
	r.bytes += int64(n)
	return n, err
}

func checkHTTPStreamPayload(body io.Reader) error {
	decoder := json.NewDecoder(body)
	if token, err := decoder.Token(); err != nil || token != json.Delim('{') {
		return fmt.Errorf("request object: %v %v", token, err)
	}
	fields, inputs := 0, 0
	for decoder.More() {
		key, err := decoder.Token()
		if err != nil {
			return err
		}
		fields++
		if key == "input" {
			if token, err := decoder.Token(); err != nil || token != json.Delim('[') {
				return fmt.Errorf("request input array: %v %v", token, err)
			}
			for decoder.More() {
				var item struct {
					Role    string `json:"role"`
					Content string `json:"content"`
					Index   int    `json:"index"`
				}
				if err := decoder.Decode(&item); err != nil {
					return err
				}
				inputs++
				if item.Role != "user" || item.Index != inputs || item.Content != strings.Repeat("streamed value ", 1200)+strconv.Itoa(inputs) {
					return fmt.Errorf("request input %d changed", inputs)
				}
			}
			if token, err := decoder.Token(); err != nil || token != json.Delim(']') {
				return fmt.Errorf("input closing array: %v %v", token, err)
			}
		} else {
			var value any
			if err := decoder.Decode(&value); err != nil {
				return err
			}
			switch key {
			case "model":
				if value != "fixture-model" {
					return fmt.Errorf("model changed: %v", value)
				}
			case "store":
				if value != false {
					return fmt.Errorf("store changed: %v", value)
				}
			case "max_output_tokens":
				if value != float64(7) {
					return fmt.Errorf("output limit changed: %v", value)
				}
			case "tools":
				if array, ok := value.([]any); !ok || len(array) != 0 {
					return fmt.Errorf("empty array changed: %v", value)
				}
			default:
				return fmt.Errorf("unexpected request field %v", key)
			}
		}
	}
	if token, err := decoder.Token(); err != nil || token != json.Delim('}') || inputs != 640 || fields != 5 {
		return fmt.Errorf("request tail: %v %v, fields=%d inputs=%d", token, err, fields, inputs)
	}
	if _, err := decoder.Token(); err != io.EOF {
		return fmt.Errorf("request has trailing data: %v", err)
	}
	return nil
}

const httpStreamScenario = `
package.path=arg[1] .. "/?.lua;" .. package.path
local json,Client,http=require("json"),require("client"),require("asenta.http")
local base=arg[2]
local function collect(value,width)
  local reader,length=json.reader(value)
  local parts={}
  while true do
    local part=reader(width)
    if part==nil then break end
    assert(#part>0 and #part<=width)
    parts[#parts+1]=part
  end
  local body=table.concat(parts)
  assert(#body==length and reader(width)==nil)
  return body
end
local function same(a,b)
  if a==b then return true end
  if type(a)~="table" or type(b)~="table" then return false end
  if ((getmetatable(a) or {}).__jsontype)~=((getmetatable(b) or {}).__jsontype) then return false end
  for key,value in pairs(a) do if not same(value,b[key]) then return false end end
  for key in pairs(b) do if a[key]==nil then return false end end
  return true
end
for _,value in ipairs({json.null,json.array(),setmetatable({}, {__jsontype="object"}),
  {n=3,[2]="middle"},{nested={1,false,json.null},text="quote \" slash \\ newline\n",number=1.25}}) do
  assert(same(json.decode(collect(value,3)),json.decode(json.encode(value))),"streaming JSON changed the wire shape")
end
local cycle={};cycle.self=cycle
assert(not pcall(json.reader,cycle))

local loads=0
local weak=setmetatable({}, {__mode="v"})
local sequence=setmetatable({}, {__jsontype="array",__len=function() return 640 end,
  __index=function(_,index)
    assert(index>=1 and index<=640)
    loads=loads+1
    local item={role="user",index=index,content=string.rep("streamed value ",1200) .. index}
    weak[1]=item
    return item
  end})
local client=Client.new({server={baseUrl=base},transport={maxBytes=16*1024*1024,timeoutMs=5000}})
local response={}
local decoded,status,headers=client:request("POST","/upload",{model="fixture-model",store=false,
  max_output_tokens=7,input=sequence,tools=json.array()},false,{headers={Authorization="Bearer fixture-header",["X-Fixture"]="stream"},
  consume=function(chunk) response[#response+1]=chunk end})
assert(status==200 and next(decoded)==nil and json.decode(table.concat(response)).files==640)
assert(headers:lower():find("x%-upload%-result: fixture") and loads==1280,"array was materialized or traversed again")
collectgarbage("collect")
assert(weak[1]==nil,"upload retained a sequence record")
assert(collectgarbage("count")<2048,"upload retained the encoded request")

local consumed=false
local ok,err=pcall(client.request,client,"POST","/error",{small=true},false,
  {consume=function() consumed=true end})
assert(not ok and err.status==503 and err.reason=="fixture_rejected" and not consumed)
assert(err.headers:lower():find("x%-upload%-result: fixture"))
assert(client:request("GET","/retry",{small=true}).ok,"safe retry reused an exhausted body reader")
assert(client:request("PATCH","/raw",{ignored=true},false,{rawBody='{"raw":true}',
  headers={["Content-Type"]="application/custom+json"}}).ok)

local function upload(path,reader,size)
  return http.request{method="POST",url=base .. path,bodyReader=reader,bodyBytes=size,maxBytes=1024,timeoutMs=2000}
end
local emptyStatus=upload("/empty",function(max) assert(max>0); return nil end,0)
assert(emptyStatus==200)
local shortCalls=0
local code,why=upload("/short",function(max)
  shortCalls=shortCalls+1; if shortCalls==1 then assert(max==10);return "abc" end
end,10)
assert(code==nil and tostring(why):find("before bodyBytes",1,true))
local longCalls=0
code,why=upload("/long",function()
  longCalls=longCalls+1;return longCalls==1 and "abc" or "x"
end,3)
assert(code==nil and tostring(why):find("exceeds bodyBytes",1,true))
code,why=upload("/oversized",function(max) return string.rep("x",max+1) end,3)
assert(code==nil and tostring(why):find("oversized",1,true))
local marker={reason="callback_failed"}
code,why=upload("/callback",function() error(marker,0) end,1)
assert(code==nil and why==marker,"native upload lost the callback error")
code,why=upload("/zero-extra",function() return "x" end,0)
assert(code==nil and tostring(why):find("exceeds bodyBytes",1,true))
local called=false
assert(not pcall(upload,"/bound",function() called=true end,1025) and not called)
`
