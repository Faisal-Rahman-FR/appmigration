import type {Reporter,TestCase,TestResult,FullResult} from '@playwright/test/reporter';
import {mkdirSync,writeFileSync} from 'node:fs';
import {resolve} from 'node:path';

export default class JsonReporter implements Reporter {
  private readonly startedAt=new Date().toISOString();
  private readonly rows:Array<Record<string,unknown>>=[];
  onTestEnd(test:TestCase,result:TestResult):void {
    this.rows.push({title:test.titlePath().join(' > '),file:test.location.file,status:result.status,expectedStatus:test.expectedStatus,
      durationMs:result.duration,annotations:test.annotations.map(a=>({type:a.type,description:a.description})),
      error:result.error ? {message:'Test failed; see local Playwright console for assertion details.'}:undefined});
  }
  onEnd(result:FullResult):void {
    const runId=this.startedAt.replace(/[:.]/g,'-');
    const directory=resolve(__dirname,'..','results',runId);
    mkdirSync(directory,{recursive:true});
    writeFileSync(resolve(directory,'results.json'),JSON.stringify({
      startedAt:this.startedAt,finishedAt:new Date().toISOString(),status:result.status,
      dotnetOptedIn:process.env.RUN_DOTNET_TESTS==='1',tests:this.rows,
    },null,2));
  }
}
