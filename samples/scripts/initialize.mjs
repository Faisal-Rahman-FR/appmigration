import {readFileSync,writeFileSync,mkdirSync,existsSync,chmodSync,unlinkSync} from 'node:fs';
import {resolve,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
process.chdir(root);
process.umask(0o077);
if(existsSync('.local/demo.env'))throw new Error('Already initialized. Preserve credentials and volumes together.');
const parse=p=>Object.fromEntries(readFileSync(p,'utf8').split(/\r?\n/).filter(l=>/^[A-Z_]+=/.test(l)).map(l=>l.split(/=(.*)/s).slice(0,2)));
const settings={...parse('.env.sample'),...(process.argv[2]?parse(process.argv[2]):{})};
for(const [k,v] of Object.entries(settings)) if(!process.env[k])process.env[k]=v;
const origins=['CAS_ORIGIN','IDP_ORIGIN','HR_ORIGIN','DRUPAL_ORIGIN','ALUMNI_ORIGIN','STUDENT_ORIGIN','EVENTS_ORIGIN'].map(k=>{
  const u=new URL(process.env[k]);
  if(u.protocol!=='https:' || u.pathname!=='/' || u.username || u.password || u.search || u.hash || (u.port&&u.port!=='443'))throw new Error(`${k} must be an HTTPS origin on443`);
  return u.hostname;
});
const openssl=(...args)=>{
  const result=spawnSync('openssl',args,{stdio:['ignore','ignore','pipe'],encoding:'utf8'});
  if(result.error||result.status!==0)throw new Error('OpenSSL failed: '+(result.error?.message??result.stderr));
};
openssl('version');
mkdirSync('.local/tls',{recursive:true,mode:0o700});
openssl('req','-x509','-newkey','rsa:3072','-nodes','-sha256','-days','730','-subj','/CN=Princeton Synthetic Demo CA','-addext','basicConstraints=critical,CA:TRUE','-addext','keyUsage=critical,keyCertSign,cRLSign','-keyout','.local/tls/ca.key','-out','.local/tls/ca.crt');
for(const name of ['gateway','idp-signing','idp-encryption','drupal','student']){
  const base=`.local/tls/${name}`;
  const extensions='basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\n'+(name==='gateway'?'extendedKeyUsage=serverAuth\nsubjectAltName='+origins.map(n=>'DNS:'+n).join(',')+'\n':'');
  writeFileSync(base+'.ext',extensions,{mode:0o600});
  openssl('req','-new','-newkey','rsa:3072','-nodes','-subj',`/CN=${name} Demo`,'-keyout',base+'.key','-out',base+'.csr');
  openssl('x509','-req','-sha256','-days','365','-in',base+'.csr','-CA','.local/tls/ca.crt','-CAkey','.local/tls/ca.key','-CAcreateserial','-extfile',base+'.ext','-out',base+'.crt');
  chmodSync(base+'.key',0o600); unlinkSync(base+'.csr'); unlinkSync(base+'.ext');
}
await import('./configure.mjs');
console.log('Locally generated TLS and app configuration only; no dependency install, build or test was run.');
