package demo.hr;

import java.time.Duration;
import java.util.LinkedHashMap;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.http.client.SimpleClientHttpRequestFactory;
import org.springframework.security.oauth2.client.oidc.userinfo.OidcUserRequest;
import org.springframework.security.oauth2.client.oidc.userinfo.OidcUserService;
import org.springframework.security.oauth2.client.userinfo.OAuth2UserService;
import org.springframework.security.oauth2.core.OAuth2AuthenticationException;
import org.springframework.security.oauth2.core.OAuth2Error;
import org.springframework.security.oauth2.core.oidc.OidcUserInfo;
import org.springframework.security.oauth2.core.oidc.user.DefaultOidcUser;
import org.springframework.security.oauth2.core.oidc.user.OidcUser;
import org.springframework.stereotype.Service;
import org.springframework.web.client.RestClient;
import org.springframework.web.client.RestClientException;

@Service
@ConditionalOnProperty(name = "demo.auth", havingValue = "entra")
public class EntraUserService implements OAuth2UserService<OidcUserRequest, OidcUser> {
    private static final Logger log = LoggerFactory.getLogger(EntraUserService.class);
    private final OidcUserService delegate = new OidcUserService();
    private final RestClient graph;
    private final String tenant;

    public EntraUserService(@org.springframework.beans.factory.annotation.Value("${ENTRA_TENANT_ID}") String tenant) {
        this.tenant = tenant;
        var factory = new SimpleClientHttpRequestFactory();
        factory.setConnectTimeout(Duration.ofSeconds(5));
        factory.setReadTimeout(Duration.ofSeconds(10));
        graph = RestClient.builder().requestFactory(factory).baseUrl("https://graph.microsoft.com/v1.0").build();
    }

    record GraphProfile(String id, String mailNickname, String employeeId, String mail, String displayName) {}

    @Override
    public OidcUser loadUser(OidcUserRequest request) {
        var user = delegate.loadUser(request);
        validateTenant(user, tenant);
        GraphProfile profile;
        try {
            profile = graph.get().uri("/me?$select=id,mailNickname,employeeId,mail,displayName")
                .headers(h -> h.setBearerAuth(request.getAccessToken().getTokenValue()))
                .retrieve().body(GraphProfile.class);
        } catch (RestClientException exception) {
            log.warn("Entra profile lookup failed ({})", exception.getClass().getSimpleName());
            throw new OAuth2AuthenticationException(new OAuth2Error("profile_lookup_failed"),
                "Cannot retrieve the required employee profile from Microsoft Graph");
        }
        return withProfile(user, profile);
    }

    static OidcUser withProfile(OidcUser user, GraphProfile profile) {
        if (profile == null || !java.util.Objects.equals(profile.id(), user.getIdToken().getClaimAsString("oid"))
                || blank(profile.mailNickname()) || blank(profile.employeeId())
                || blank(profile.mail()) || blank(profile.displayName())) {
            log.warn("Entra employee profile rejected: uid={}, objectIdMatches={}, nicknamePresent={}, employeeIdPresent={}, mailPresent={}, displayNamePresent={}",
                profile == null ? "(missing)" : profile.mailNickname(),
                profile != null && java.util.Objects.equals(profile.id(), user.getIdToken().getClaimAsString("oid")),
                profile != null && !blank(profile.mailNickname()), profile != null && !blank(profile.employeeId()),
                profile != null && !blank(profile.mail()), profile != null && !blank(profile.displayName()));
            throw new OAuth2AuthenticationException(new OAuth2Error("invalid_employee_profile"),
                "The employee profile must match the token and contain mailNickname, employeeId, mail and displayName");
        }
        var claims = new LinkedHashMap<String, Object>();
        claims.put("sub", user.getSubject());
        claims.put("uid", profile.mailNickname());
        claims.put("employeeNumber", profile.employeeId());
        claims.put("mail", profile.mail());
        claims.put("displayName", profile.displayName());
        log.info("HR Entra employee profile accepted: uid={}", profile.mailNickname());
        return new DefaultOidcUser(user.getAuthorities(), user.getIdToken(),
            new OidcUserInfo(claims), "sub");
    }

    private static boolean blank(String value) { return value == null || value.isBlank(); }

    static void validateTenant(OidcUser user, String tenant) {
        if (!tenant.equals(user.getIdToken().getClaimAsString("tid"))) {
            log.warn("Entra ID token tenant claim does not match the configured tenant");
            throw new OAuth2AuthenticationException(new OAuth2Error("invalid_tenant"),
                "The ID token tenant claim does not match the configured tenant");
        }
    }

    static Identity identity(OidcUser user) {
        var attributes = new LinkedHashMap<String, Object>();
        for (String name : java.util.List.of("mail", "displayName", "employeeNumber")) {
            attributes.put(name, user.getClaimAsString(name));
        }
        var roles = user.getIdToken().getClaimAsStringList("roles");
        attributes.put("memberOf", roles == null ? java.util.List.of() : roles);
        return new Identity(user.getClaimAsString("uid"), attributes);
    }
}
