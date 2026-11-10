import {readFileSync, writeFileSync, mkdirSync, existsSync} from 'node:fs';
import {resolve, dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import {randomBytes, createHash} from 'node:crypto';
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
process.chdir(root);
const read = p => readFileSync(p, 'utf8');
const save = (p, value) => { mkdirSync(dirname(p), {recursive:true}); writeFileSync(p, value, {mode:0o600}); };
const values = Object.fromEntries(read('.env.sample').split(/\r?\n/).filter(l=>/^[A-Z_]+=/.test(l)).map(l=>l.split(/=(.*)/s).slice(0,2)));
// Optional origin overrides are passed as process environment, not treated as shell code.
for (const k of Object.keys(values)) if (process.env[k]) values[k] = process.env[k];
for (const k of ['CAS_ORIGIN','IDP_ORIGIN','HR_ORIGIN','DRUPAL_ORIGIN','ALUMNI_ORIGIN','STUDENT_ORIGIN','EVENTS_ORIGIN']) {
  const u = new URL(values[k]);
  if (u.protocol !== 'https:' || u.pathname !== '/' || u.search || u.hash || u.username || u.password || (u.port && u.port !== '443')) throw Error(`${k} must be an HTTPS origin on port 443.`);
  values[k] = u.origin;
  values[k.replace('_ORIGIN','_HOST')] = u.hostname;
}
if (existsSync('.local/demo.env')) throw Error('Refusing to overwrite operational credentials.');
for (const k of ['LDAP_ADMIN_PASSWORD','LDAP_BIND_PASSWORD','DB_ROOT_PASSWORD','DB_PASSWORD','DRUPAL_ADMIN_PASSWORD','IDP_SEALER_PASSWORD','CAS_WEBFLOW_SIGNING_KEY','CAS_WEBFLOW_ENCRYPTION_KEY']) values[k] = randomBytes(k === 'CAS_WEBFLOW_SIGNING_KEY' ? 64 : k === 'CAS_WEBFLOW_ENCRYPTION_KEY' ? 16 : 24).toString('base64url');
save('.local/demo.env', Object.entries(values).map(([k,v])=>`${k}=${v}`).join('\n')+'\n');
const xml = s => String(s).replace(/[<>&"']/g,c=>({'<':'&lt;','>':'&gt;','&':'&amp;','"':'&quot;',"'":'&apos;'}[c]));
const render = (src,dst) => save(dst, read(src).replace(/@@([A-Z_]+)@@/g,(_,k)=>{if(!(k in values))throw Error(`Missing ${k}`);return values[k];}));
const cert = name => read(`.local/tls/${name}.crt`).replace(/-----[^-]+-----|\s/g,'');
values.IDP_SIGNING_CERT=cert('idp-signing'); values.DRUPAL_CERT=cert('drupal'); values.STUDENT_CERT=cert('student');
const users = JSON.parse(read('idp/ldap/users.json'));
const passwords = Object.fromEntries(users.map(u=>[u.uid,randomBytes(18).toString('base64url')]));
save('.local/test-users.json', JSON.stringify(passwords,null,2));
let ldif='dn: ou=people,dc=demo,dc=test\nobjectClass: organizationalUnit\nou: people\n\ndn: ou=groups,dc=demo,dc=test\nobjectClass: organizationalUnit\nou: groups\n\n';
for (const u of users) {
  const salt=randomBytes(8), hash=createHash('sha1').update(passwords[u.uid]).update(salt).digest();
  ldif+=`dn: uid=${u.uid},ou=people,dc=demo,dc=test\nobjectClass: inetOrgPerson\nobjectClass: eduPerson\n`;
  for (const k of ['uid','mail','displayName','employeeNumber','eduPersonAffiliation','eduPersonPrincipalName','givenName','sn']) for(const v of [].concat(u[k])) ldif+=`${k}: ${v}\n`;
  ldif+=`cn: ${u.displayName}\nuserPassword: {SSHA}${Buffer.concat([hash,salt]).toString('base64')}\n\n`;
}
for(const g of new Set(users.flatMap(u=>u.groups))) ldif+=`dn: cn=${g},ou=groups,dc=demo,dc=test\nobjectClass: groupOfUniqueNames\ncn: ${g}\n`+users.filter(u=>u.groups.includes(g)).map(u=>`uniqueMember: uid=${u.uid},ou=people,dc=demo,dc=test\n`).join('')+'\n';
save('.local/ldap/50-users.ldif',ldif);
render('gateway/nginx.conf.template','.local/nginx.conf');
render('idp/cas/cas.properties.template','.local/cas/cas.properties');
const manifest=JSON.parse(read('manifest.yaml'));
for (const [id,serviceId,attrs] of [
  ['hr',values.HR_ORIGIN,['uid','mail','displayName','employeeNumber','memberOf','eduPersonAffiliation']],
  ['alumni',values.ALUMNI_ORIGIN,['uid','mail','displayName','eduPersonAffiliation']],
  ['events',values.EVENTS_ORIGIN,['uid']]
]) {
  const sample=manifest.samples.find(sample=>sample.id===id);
  if(!sample)throw Error(`Missing manifest identity for ${id}`);
  // mod_auth_cas does not implement back-channel single logout, so the events service registers none.
  const logout=id==='events'?{logoutType:'NONE'}:{logoutType:'BACK_CHANNEL',logoutUrl:serviceId+'/slo'};
  save(`.local/cas/services/${id}.json`,JSON.stringify({'@class':'org.apereo.cas.services.CasRegisteredService',id:{hr:101,alumni:102,events:103}[id],name:sample.name,description:`${sample.useCase} — ${sample.name}`,serviceId:serviceId.replace(/[.*+?^${}()|[\]\\]/g,'\\$&')+'/.*',...logout,attributeReleasePolicy:{'@class':'org.apereo.cas.services.ReturnAllowedAttributeReleasePolicy',allowedAttributes:['java.util.ArrayList',attrs]}},null,2));
}
for (const f of ['idp.properties','ldap.properties','attribute-resolver.xml','attribute-filter.xml','relying-party.xml','metadata-providers.xml','saml-nameid.properties']) render(`idp/shibboleth/conf/${f}.template`,`.local/shibboleth/conf/${f}`);
render('idp/shibboleth/metadata/sp-metadata.xml.template','.local/shibboleth/metadata/sp-metadata.xml');
render('apps/dotnet-shibsp/shibboleth/shibboleth2.xml.template','.local/windows/shibboleth2.xml');
render('apps/dotnet-shibsp/Web.Demo.config.template','.local/windows/Web.Demo.config');
save('.local/idp-metadata.xml',`<EntityDescriptor xmlns="urn:oasis:names:tc:SAML:2.0:metadata" xmlns:ds="http://www.w3.org/2000/09/xmldsig#" xmlns:shibmd="urn:mace:shibboleth:metadata:1.0" entityID="${xml(values.IDP_ORIGIN)}/idp/shibboleth"><IDPSSODescriptor protocolSupportEnumeration="urn:oasis:names:tc:SAML:2.0:protocol" WantAuthnRequestsSigned="true"><Extensions><shibmd:Scope regexp="false">demo.test</shibmd:Scope></Extensions><KeyDescriptor use="signing"><ds:KeyInfo><ds:X509Data><ds:X509Certificate>${values.IDP_SIGNING_CERT}</ds:X509Certificate></ds:X509Data></ds:KeyInfo></KeyDescriptor><SingleLogoutService Binding="urn:oasis:names:tc:SAML:2.0:bindings:HTTP-Redirect" Location="${xml(values.IDP_ORIGIN)}/idp/profile/SAML2/Redirect/SLO"/><SingleSignOnService Binding="urn:oasis:names:tc:SAML:2.0:bindings:HTTP-Redirect" Location="${xml(values.IDP_ORIGIN)}/idp/profile/SAML2/Redirect/SSO"/></IDPSSODescriptor></EntityDescriptor>\n`);
save('.local/drupal/settings.secrets.php',`<?php\n$settings['hash_salt'] = '${randomBytes(32).toString('hex')}';\n`);
console.log('Generated configuration, metadata and synthetic credentials. No services started or tests run.');
