import {lookup} from 'node:dns/promises';
import {origin,originKeys} from './environment';

function privateAddress(ip:string):boolean {
  if(ip==='::1' || /^f[cd][0-9a-f]{2}:/i.test(ip)) return true;
  const parts=ip.split('.').map(Number);
  return parts.length===4 && (parts[0]===127 || parts[0]===10 || (parts[0]===192 && parts[1]===168) || (parts[0]===172 && parts[1]>=16 && parts[1]<=31));
}
export default async function setup():Promise<void> {
  const keys=[...originKeys,...(process.env.RUN_DOTNET_TESTS==='1'?['STUDENT_ORIGIN']:[])];
  for(const key of keys) {
    const addresses=await lookup(new URL(origin(key)).hostname,{all:true});
    if(!addresses.length || addresses.some(a=>!privateAddress(a.address))) throw new Error(`${key} must resolve only to loopback/private addresses. Tests never target the public Internet.`);
  }
}
