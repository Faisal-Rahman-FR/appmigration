package org.apereo.cas.web.demo;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;
import javax.naming.Context;
import javax.naming.directory.InitialDirContext;
import java.util.Hashtable;
import java.util.Map;

@RestController
public class DemoHealthController {
    @Value("${cas.authn.ldap[0].bind-credential}") private String password;
    @GetMapping("/healthz")
    public Map<String,String> health() { return Map.of("status", "ok"); }
    @GetMapping("/readyz")
    public ResponseEntity<Map<String,String>> ready() {
        var env = new Hashtable<String,String>();
        env.put(Context.INITIAL_CONTEXT_FACTORY, "com.sun.jndi.ldap.LdapCtxFactory");
        env.put(Context.PROVIDER_URL, "ldap://ldap:389");
        env.put(Context.SECURITY_AUTHENTICATION, "simple");
        env.put(Context.SECURITY_PRINCIPAL, "cn=readonly,dc=demo,dc=test");
        env.put(Context.SECURITY_CREDENTIALS, password);
        env.put("com.sun.jndi.ldap.connect.timeout", "3000");
        env.put("com.sun.jndi.ldap.read.timeout", "3000");
        try {
            var context = new InitialDirContext(env);
            try { context.getAttributes("uid=alice,ou=people,dc=demo,dc=test", new String[]{"uid"}); }
            finally { context.close(); }
            return ResponseEntity.ok(Map.of("status", "ready"));
        } catch (Exception exception) {
            return ResponseEntity.status(503).body(Map.of("status", "notReady"));
        }
    }
}
