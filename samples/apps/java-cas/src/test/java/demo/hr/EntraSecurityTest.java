package demo.hr;

import java.util.List;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Import;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.oauth2.client.registration.ClientRegistration;
import org.springframework.security.oauth2.client.registration.ClientRegistrationRepository;
import org.springframework.security.oauth2.client.registration.InMemoryClientRegistrationRepository;
import org.springframework.security.oauth2.core.AuthorizationGrantType;
import org.springframework.security.oauth2.core.oidc.IdTokenClaimNames;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.web.util.UriComponentsBuilder;
import static org.junit.jupiter.api.Assertions.*;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

@WebMvcTest(controllers = EntraPortalController.class, properties = {
    "demo.auth=entra", "HR_ORIGIN=https://hr.demo.test",
    "spring.config.import=classpath:application-entra.properties",
    "ENTRA_CLIENT_ID=test-client", "ENTRA_CLIENT_SECRET=test-secret", "ENTRA_TENANT_ID=test-tenant"
})
@Import({SecurityConfiguration.class, EntraUserService.class, EntraSecurityTest.Clients.class})
class EntraSecurityTest {
    @Autowired MockMvc mvc;
    @Autowired ClientRegistrationRepository clients;
    @Autowired org.springframework.core.env.Environment environment;

    @TestConfiguration
    static class Clients {
        @Bean ClientRegistrationRepository clients() {
            return new InMemoryClientRegistrationRepository(ClientRegistration.withRegistrationId("entra")
                .clientId("test-client").clientSecret("test-secret")
                .authorizationGrantType(AuthorizationGrantType.AUTHORIZATION_CODE)
                .redirectUri("https://hr.demo.test/login/oauth2/code/entra").scope("openid", "profile", "email")
                .authorizationUri("https://login.microsoftonline.com/test-tenant/oauth2/v2.0/authorize")
                .tokenUri("https://login.microsoftonline.com/test-tenant/oauth2/v2.0/token")
                .jwkSetUri("https://login.microsoftonline.com/test-tenant/discovery/v2.0/keys")
                .userInfoUri("https://graph.microsoft.com/oidc/userinfo")
                .userNameAttributeName(IdTokenClaimNames.SUB)
                .providerConfigurationMetadata(java.util.Map.of("end_session_endpoint",
                    "https://login.microsoftonline.com/test-tenant/oauth2/v2.0/logout"))
                .build());
        }
    }

    @Test void publicHomeAndAnonymousChallenge() throws Exception {
        assertEquals("sub", environment.getProperty("spring.security.oauth2.client.provider.entra.user-name-attribute"));
        mvc.perform(get("/")).andExpect(status().isOk())
            .andExpect(content().string(org.hamcrest.Matchers.containsString("Sign in with Microsoft Entra ID")));
        mvc.perform(get("/profile")).andExpect(status().is3xxRedirection())
            .andExpect(redirectedUrl("http://localhost/oauth2/authorization/entra"));
    }

    @Test void authorizationRequestIncludesPkceStateNonceAndExactRedirect() throws Exception {
        var response = mvc.perform(get("/oauth2/authorization/entra")).andExpect(status().is3xxRedirection())
            .andReturn().getResponse();
        var params = UriComponentsBuilder.fromUriString(response.getRedirectedUrl()).build().getQueryParams();
        assertEquals("S256", params.getFirst("code_challenge_method"));
        assertNotNull(params.getFirst("code_challenge"));
        assertNotNull(params.getFirst("state"));
        assertNotNull(params.getFirst("nonce"));
        assertEquals("https://hr.demo.test/login/oauth2/code/entra", params.getFirst("redirect_uri"));
    }

    @Test void roleAllowedAndDeniedAndLegacyCallbackDisabled() throws Exception {
        mvc.perform(get("/admin").with(oidcLogin().idToken(t -> t.claim("roles", List.of("member")))))
            .andExpect(status().isForbidden());
        mvc.perform(get("/admin").with(oidcLogin().authorities(new SimpleGrantedAuthority("APPROLE_hr-admins"))))
            .andExpect(status().isOk()).andExpect(view().name("admin"))
            .andExpect(content().string(org.hamcrest.Matchers.containsString("hr-admins application role")));
        mvc.perform(get("/slo").with(oidcLogin())).andExpect(status().isForbidden());
        mvc.perform(post("/slo").with(oidcLogin()).with(csrf())).andExpect(status().isForbidden());
    }

    @Test void profileRendersAttributesAndSpringCsrfField() throws Exception {
        mvc.perform(get("/profile").with(oidcLogin().idToken(t -> t.claim("uid", "testuser1")
                .claim("employeeNumber", "10001").claim("mail", "test@example.test")
                .claim("displayName", "Test User").claim("roles", List.of("hr-admins")))))
            .andExpect(status().isOk()).andExpect(content().string(org.hamcrest.Matchers.containsString("10001")))
            .andExpect(content().string(org.hamcrest.Matchers.containsString("name=\"_csrf\"")))
            .andExpect(content().string(org.hamcrest.Matchers.not(org.hamcrest.Matchers.containsString("test-token"))));
    }

    @Test void logoutRequiresCsrfAndInvalidatesSessionBeforeEntraRedirect() throws Exception {
        mvc.perform(post("/logout").with(oidcLogin())).andExpect(status().isForbidden());
        mvc.perform(get("/logout").with(oidcLogin())).andExpect(status().isNotFound());
        var result = mvc.perform(post("/logout").secure(true).with(csrf())
                .with(oidcLogin().clientRegistration(clients.findByRegistrationId("entra"))))
            .andExpect(status().is3xxRedirection()).andReturn();
        assertTrue(result.getRequest().getSession(false) == null);
        var location = result.getResponse().getRedirectedUrl();
        assertTrue(location.startsWith("https://login.microsoftonline.com/test-tenant/oauth2/v2.0/logout?"));
        assertTrue(location.contains("post_logout_redirect_uri=https://hr.demo.test/"));
    }

    @Test void callbackFailureShowsErrorInsteadOfRedirectLoop() throws Exception {
        var result = mvc.perform(get("/login/oauth2/code/entra").param("error", "access_denied").param("state", "unknown"))
            .andExpect(status().is3xxRedirection()).andExpect(redirectedUrl("/login-error")).andReturn();
        mvc.perform(get("/login-error").session((org.springframework.mock.web.MockHttpSession) result.getRequest().getSession()))
            .andExpect(status().isUnauthorized())
            .andExpect(content().string(org.hamcrest.Matchers.containsString("HR sign-in failed")));
    }
}
