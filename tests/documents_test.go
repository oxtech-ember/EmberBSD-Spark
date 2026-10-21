package probe

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

func TestWholeAnswerAttachmentReplay(t *testing.T) {
	directory := t.TempDir()
	script := filepath.Join(directory, "documents.lua")
	if err := os.WriteFile(script, []byte(`package.path=arg[1] .. "/?.lua;" .. package.path
local Documents, json, fs = require("documents"), require("json"), require("asenta.fs")
local result={whole='{"large":"' .. string.rep("x",150) .. '","after":42}\n',output="A bounded head.",
    error=false,foreign=true,raw={structuredContent={after=42}}}
local task,call={taskId="task/one"},{name="device.state",id="call/one"}
local context={toolOutput=64,stepId="attempt/step",composed=true,title='Device / state: * ? " < > | \\ .'}
local upload=Documents.prepare(task,call,result,context)
assert(upload.body == result.whole and upload.contentType == "application/json" and upload.composed)
assert(upload.requestId == "attempt/step/call/one/whole" and upload.taskId == task.taskId)
assert(upload.filename:sub(-5) == ".json" and upload.filename:find(fs.sha256(result.whole):sub(1,8),1,true))
assert(not upload.filename:find('[/\\:*?"<>|]'))
-- Simulate the durable pending effect, then a reply lost AFTER the upload.
local saved=json.decode(json.encode({call=call,result=result,upload=upload}))
local calls,stored,firstPath=0,0,nil
local client={}
local mode="lost"
function client:request(method,path,value,model,options)
    calls=calls+1
    assert(method == "POST" and value == nil and model == false)
    assert(path:find("/api/v1/tasks/task%2Fone/attachments?",1,true) == 1)
    assert(path:find("requestId=attempt%2Fstep%2Fcall%2Fone%2Fwhole",1,true))
    assert(path:find("&composed=true",1,true))
    assert(options.rawBody == result.whole and options.headers["Content-Type"] == "application/json")
    assert(options.maxBytes == 1024*1024)
    if mode == "refused" then error({status=413,reason="too_large",message="Body is too large"},0) end
    if mode == "unconfigured" then error({status=503,reason="no_storage",message="No storage configured"},0) end
    if mode == "temporary" then error({status=503,reason="storage_unavailable",message="Storage is busy"},0) end
    if not firstPath then firstPath=path;stored=stored+1 else assert(path == firstPath) end
    if mode == "lost" then mode="success";error({message="response connection lost"},0) end
    return {attachment={attachmentId="kept-once",taskId=task.taskId,filename=upload.filename,
        sha256=fs.sha256(options.rawBody),size=#options.rawBody,composed=true}}
end
local ok,why=pcall(Documents.keep,client,task,saved.call,saved.result,{upload=saved.upload})
assert(not ok and why.message == "response connection lost" and stored == 1)
-- Live registry captions can change after restart; the frozen upload wins.
local kept=Documents.keep(client,task,saved.call,saved.result,{upload=saved.upload,title="A changed title"})
assert(calls == 2 and stored == 1 and kept.attachment.attachmentId == "kept-once")
assert(kept.output:find(upload.filename,1,true) and kept.output:find("no document reader",1,true))
assert(kept.whole == result.whole and kept.raw.structuredContent.after == 42 and not kept.error and kept.foreign)
assert(result.attachment == nil and result.output == "A bounded head.")
assert(Documents.keep(client,task,call,kept,{upload=upload}) == kept and calls == 2)
local short={whole="fits",output="fits"}
assert(Documents.prepare(task,call,short,{toolOutput=64}) == nil)
assert(Documents.keep(client,task,call,short) == short and calls == 2)
assert(Documents.prepare(task,call,result,{aside=true}) == nil)
assert(#Documents.tools(client,task,{}) == 0)
mode="refused"
local refused=Documents.keep(client,task,call,result,{upload=upload})
assert(refused.attachment == nil and refused.attachmentError.reason == "too_large")
assert(refused.output:find("could not be attached",1,true) and not refused.error)
mode="unconfigured"
assert(Documents.keep(client,task,call,result,{upload=upload}).attachmentError.reason == "no_storage")
mode="temporary"
ok,why=pcall(Documents.keep,client,task,call,result,{upload=upload})
assert(not ok and why.reason == "storage_unavailable")
local brought=Documents.prepare(task,call,{whole=string.rep("plain ",20),output="head"},
    {toolOutput=64,requestId="exact-key",composed=false})
assert(brought.requestId == "exact-key" and not brought.composed)
assert(brought.filename:sub(-4) == ".txt" and brought.contentType == "text/plain; charset=utf-8")
`), 0600); err != nil {
		t.Fatal(err)
	}
	binary, err := filepath.Abs("../build/agent-lua")
	if err != nil {
		t.Fatal(err)
	}
	modules, err := filepath.Abs("../lua")
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, binary, script, modules)
	if output, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("whole answer attachment contract failed: %v\n%s", err, output)
	}
}
