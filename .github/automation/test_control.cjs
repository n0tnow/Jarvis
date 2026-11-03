const {test} = require('node:test');
const assert = require('node:assert/strict');
const control = require('./control.cjs');
const context = {repo:{owner:'n0tnow',repo:'Jarvis'}, eventName:'issues', actor:'n0tnow', sha:'a'.repeat(40),
  payload:{action:'labeled',label:{name:'agent:approved'}, sender:{type:'User'},issue:{number:1}}};
function fixture(labels=['agent:approved'], count=1) {
  const calls=[]; const output={};
  const github={rest:{issues:{get:async()=>({data:{state:'open',labels:labels.map(name=>({name}))}}),
    addLabels:async()=>calls.push('claim'),removeLabel:async()=>calls.push('consume'),createComment:async()=>calls.push('comment')},
    actions:{listWorkflowRuns:async()=>({data:{total_count:count}})}}};
  return {github, context:structuredClone(context), core:{setOutput:(k,v)=>output[k]=v},calls,output};
}
process.env.GITHUB_RUN_ATTEMPT='1'; process.env.HAS_CLAUDE_SECRET='true';
test('approved task is claimed before outputs are released',async()=>{
  const f=fixture(); await control(f,'gate'); assert.deepEqual(f.calls,['claim','consume','comment']); assert.equal(f.output.issue,'1');
});
test('untrusted actor, bot, PR and wrong event rejected',async()=>{
  for (const mutate of [f=>f.context.actor='outsider',f=>f.context.payload.sender.type='Bot',f=>f.context.payload.issue.pull_request={},f=>f.context.eventName='issue_comment']) {
    const f=fixture(); mutate(f); await assert.rejects(control(f,'gate')); assert.equal(f.calls.length,0);
  }
});
test('consumed approval and daily limit reject without work',async()=>{
  for (const f of [fixture([]),fixture(['agent:approved','agent:attempted']),fixture(['agent:approved'],3)]) {
    await assert.rejects(control(f,'gate')); assert.equal(f.calls.length,0);
  }
});
test('rerun blocked',async()=>{
  process.env.GITHUB_RUN_ATTEMPT='2'; await assert.rejects(control(fixture(),'gate')); process.env.GITHUB_RUN_ATTEMPT='1';
});
test('missing subscription fails closed',async()=>{
  process.env.HAS_CLAUDE_SECRET='false'; await assert.rejects(control(fixture(),'gate')); process.env.HAS_CLAUDE_SECRET='true';
});
test('moving main prevents publication',async()=>{
  process.env.BASE_SHA='a'.repeat(40); process.env.TASK_ISSUE='1';
  const f=fixture(); f.github.rest.git={getRef:async()=>({data:{object:{sha:'b'.repeat(40)}}})};
  await assert.rejects(control(f,'publish'), /Main moved/);
});
