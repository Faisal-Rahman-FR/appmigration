package demo.hr;

import java.util.Collection;
import java.util.List;
import java.util.Map;

public record Identity(String uid, Map<String, Object> attributes) {
    public List<String> values(String name) {
        Object value = attributes.get(name);
        if (value == null) return List.of();
        if (value instanceof Collection<?> values) return values.stream().map(String::valueOf).toList();
        return List.of(value.toString());
    }
    public boolean hrAdmin() {
        return values("memberOf").stream().anyMatch("cn=hr-admins,ou=groups,dc=demo,dc=test"::equalsIgnoreCase);
    }
}
