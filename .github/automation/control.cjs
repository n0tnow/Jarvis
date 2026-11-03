const fs = require('node:fs');
module.exports = async ({github, context, core}, mode) => {
  const repo = context.repo;
  const number = context.payload.issue?.number;
  const run = `${context.serverUrl}/${repo.owner}/${repo.repo}/actions/runs/${context.runId}`;
  if (mode === 'gate') {
    if (context.eventName !== 'issues' || context.payload.action !== 'labeled' ||
        context.payload.label.name !== 'agent:approved' || context.payload.issue.pull_request ||
        context.actor !== 'n0tnow' || context.payload.sender.type !== 'User' ||
        process.env.GITHUB_RUN_ATTEMPT !== '1') throw new Error('Unauthorized trigger or rerun');
    const {data: issue} = await github.rest.issues.get({...repo, issue_number: number});
    const labels = issue.labels.map(x => x.name);
    if (issue.state !== 'open' || !labels.includes('agent:approved') || labels.includes('agent:attempted'))
      throw new Error('Task closed, approval absent, or already attempted');
    if (process.env.HAS_CLAUDE_SECRET !== 'true') throw new Error('Missing CLAUDE_CODE_OAUTH_TOKEN');
    const taskPath = `agent-workflow/tasks/issue-${number}.json`;
    const task = JSON.parse(fs.readFileSync(taskPath, 'utf8'));
    if (task.issue !== number) throw new Error('Task identity mismatch');
    const {data: runs} = await github.rest.actions.listWorkflowRuns({...repo,
      workflow_id: 'agent-task.yml', actor: 'n0tnow', event: 'issues',
      created: `>=${new Date().toISOString().slice(0,10)}T00:00:00Z`, per_page: 100});
    if (runs.total_count > 2) throw new Error('Daily limit reached (2 trigger runs, UTC)');
    await github.rest.issues.addLabels({...repo, issue_number:number, labels:['agent:attempted']});
    await github.rest.issues.removeLabel({...repo, issue_number:number, name:'agent:approved'});
    await github.rest.issues.createComment({...repo, issue_number:number,
      body:`Bounded attempt claimed: ${run}. No automatic retry, merge or deployment.`});
    core.setOutput('task', taskPath);
    core.setOutput('base', context.sha);
    core.setOutput('issue', String(number));
  } else if (mode === 'publish') {
    // This job has never run model code, tests, hooks, shell fragments or PR files.
    const base = process.env.BASE_SHA;
    const issueNumber = Number(process.env.TASK_ISSUE);
    if (!/^[a-f0-9]{40}$/.test(base) || !Number.isSafeInteger(issueNumber)) throw new Error('Invalid identity');
    const {data: current} = await github.rest.git.getRef({...repo, ref:'heads/main'});
    if (current.object.sha !== base) throw new Error('Main moved; re-plan instead of rebasing automatically');
    const result = JSON.parse(fs.readFileSync('incoming/agent-output.json','utf8'));
    const {data: parent} = await github.rest.git.getCommit({...repo, commit_sha:base});
    const {data: tree} = await github.rest.git.createTree({...repo, base_tree:parent.tree.sha,
      tree:result.changes.map(x=>({path:x.path, mode:'100644', type:'blob', content:x.content}))});
    if (tree.sha === parent.tree.sha) throw new Error('No changes');
    const {data: commit} = await github.rest.git.createCommit({...repo, tree:tree.sha, parents:[base],
      message:`docs(agent): bounded task ${issueNumber} result`});
    const branch = `agent/task-${issueNumber}`;
    // Create-only: a previous branch is never overwritten, even after partial failure.
    await github.rest.git.createRef({...repo, ref:`refs/heads/${branch}`, sha:commit.sha});
    const {data: pr} = await github.rest.pulls.create({...repo, head:branch, base:'main', draft:true,
      title:`Agent task #${issueNumber}: bounded proposal`,
      body:`Related to #${issueNumber}.\n\nValidation evidence: ${run}\n\nScope/schema checks and applicable isolated unit tests passed. This is not a full verify.sh run, human acceptance or security approval. Model report is untrusted data in the run artifact. No auto-merge or deployment. Review this exact commit: ${commit.sha}.`});
    await github.rest.issues.createComment({...repo, issue_number:issueNumber, body:`Draft ready for independent review: ${pr.html_url}\nEvidence: ${run}`});
    await core.summary.addLink('Draft PR',pr.html_url).write();
  } else if (mode === 'report') {
    const states = JSON.parse(process.env.JOB_RESULTS);
    const body = `Automation result: ${Object.entries(states).map(([k,v])=>`${k}=${v.result}`).join(', ')}.\nEvidence: ${run}\nFailed/skipped work is not complete. No automatic retry. No merge or deployment.`;
    await github.rest.issues.createComment({...repo, issue_number:number, body});
    await core.summary.addRaw(body).write();
  }
};
