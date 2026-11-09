package demo.hr;

import org.junit.jupiter.api.Test;
import java.util.List;
import java.util.Map;
import static org.junit.jupiter.api.Assertions.*;

class IdentityTest {
    @Test void handlesSingleAndMultivaluedAttributes() {
        var user = new Identity("alice", Map.of("employeeNumber","10001","memberOf",List.of("cn=research,ou=groups,dc=demo,dc=test","cn=hr-admins,ou=groups,dc=demo,dc=test")));
        assertEquals(List.of("10001"), user.values("employeeNumber"));
        assertTrue(user.hrAdmin());
        assertEquals(List.of(), user.values("missing"));
    }
    @Test void refusesGroupSubstringAndMissingGroup() {
        assertFalse(new Identity("carol",Map.of()).hrAdmin());
        assertFalse(new Identity("carol",Map.of("memberOf","cn=not-hr-admins,ou=groups,dc=demo,dc=test")).hrAdmin());
    }
}
