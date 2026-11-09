<%@ page contentType="application/json; charset=UTF-8" session="false" trimDirectiveWhitespaces="true" import="java.net.*,java.util.*,javax.naming.*,javax.naming.directory.*" %><%
boolean ready = false;
try {
  HttpURLConnection status = (HttpURLConnection) URI.create("http://127.0.0.1:8080/idp/status").toURL().openConnection();
  status.setConnectTimeout(2000); status.setReadTimeout(2000); status.setInstanceFollowRedirects(false);
  try { if (status.getResponseCode() != 200) throw new Exception("IdP status unavailable"); }
  finally { status.disconnect(); }
  Hashtable<String,String> env = new Hashtable<>();
  env.put(Context.INITIAL_CONTEXT_FACTORY,"com.sun.jndi.ldap.LdapCtxFactory");
  env.put(Context.PROVIDER_URL,"ldap://ldap:389");
  env.put(Context.SECURITY_AUTHENTICATION,"simple");
  env.put(Context.SECURITY_PRINCIPAL,"cn=readonly,dc=demo,dc=test");
  env.put(Context.SECURITY_CREDENTIALS,System.getenv("LDAP_BIND_PASSWORD"));
  env.put("com.sun.jndi.ldap.connect.timeout","2000"); env.put("com.sun.jndi.ldap.read.timeout","2000");
  InitialDirContext ldap = new InitialDirContext(env);
  try { ldap.getAttributes("uid=alice,ou=people,dc=demo,dc=test",new String[]{"uid"}); }
  finally { ldap.close(); }
  ready = true;
} catch (Exception exception) { response.setStatus(503); }
%>{"status":"<%= ready ? "ready" : "notReady" %>"}
