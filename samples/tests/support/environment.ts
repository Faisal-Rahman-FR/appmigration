import {existsSync, readFileSync} from 'node:fs';
import {resolve} from 'node:path';
export const samplesRoot=resolve(__dirname,'..','..');
const file=resolve(samplesRoot,'.local','demo.env');
if(existsSync(file)) for(const line of readFileSync(file,'utf8').split(/\r?\n/)) {
  const match=/^([A-Z_]+)=(.*)$/.exec(line);
  if(match && process.env[match[1]]===undefined) process.env[match[1]]=match[2];
}
export function origin(key:string):string {
  const value=process.env[key];
  if(!value) throw new Error(`Missing ${key}; initialize the demo before browser tests.`);
  const u=new URL(value);
  if(u.protocol!=='https:' || u.origin!==value) throw new Error(`${key} must be an HTTPS origin without a trailing slash.`);
  return value;
}
export function password(uid:string):string {
  const credentials=JSON.parse(readFileSync(resolve(samplesRoot,'.local','test-users.json'),'utf8')) as Record<string,string>;
  if(!credentials[uid]) throw new Error(`No generated synthetic password for ${uid}`);
  return credentials[uid];
}
export const originKeys=['CAS_ORIGIN','IDP_ORIGIN','HR_ORIGIN','DRUPAL_ORIGIN','ALUMNI_ORIGIN','EVENTS_ORIGIN'];
