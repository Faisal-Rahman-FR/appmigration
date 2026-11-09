package demo.hr;

import java.util.HashSet;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.config.annotation.web.configurers.AbstractHttpConfigurer;
import org.springframework.security.core.GrantedAuthority;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.oauth2.client.oidc.web.logout.OidcClientInitiatedLogoutSuccessHandler;
import org.springframework.security.oauth2.client.registration.ClientRegistrationRepository;
import org.springframework.security.oauth2.client.web.DefaultOAuth2AuthorizationRequestResolver;
import org.springframework.security.oauth2.client.web.OAuth2AuthorizationRequestCustomizers;
import org.springframework.security.oauth2.core.oidc.user.OidcUserAuthority;
import org.springframework.security.web.SecurityFilterChain;
import org.springframework.security.web.util.matcher.AntPathRequestMatcher;

@Configuration
public class SecurityConfiguration {
    private static final org.slf4j.Logger log = org.slf4j.LoggerFactory.getLogger(SecurityConfiguration.class);
    public SecurityConfiguration(@Value("${demo.auth:cas}") String auth) {
        if (!java.util.Set.of("cas", "entra").contains(auth)) {
            throw new IllegalArgumentException("DEMO_AUTH must be cas or entra");
        }
    }

    @Bean
    @ConditionalOnProperty(name = "demo.auth", havingValue = "cas", matchIfMissing = true)
    SecurityFilterChain casChain(HttpSecurity http) throws Exception {
        // The legacy CAS filters and controller retain their existing CSRF/logout boundary.
        return http.authorizeHttpRequests(a -> a.anyRequest().permitAll())
            .csrf(AbstractHttpConfigurer::disable)
            .logout(AbstractHttpConfigurer::disable)
            .requestCache(AbstractHttpConfigurer::disable)
            .build();
    }

    @Bean
    @ConditionalOnProperty(name = "demo.auth", havingValue = "entra")
    SecurityFilterChain entraChain(HttpSecurity http, ClientRegistrationRepository clients,
            EntraUserService users, @Value("${demo.app-origin}") String origin) throws Exception {
        var authorization = new DefaultOAuth2AuthorizationRequestResolver(clients, "/oauth2/authorization");
        authorization.setAuthorizationRequestCustomizer(OAuth2AuthorizationRequestCustomizers.withPkce());
        var logout = new OidcClientInitiatedLogoutSuccessHandler(clients);
        logout.setPostLogoutRedirectUri(origin + "/");
        return http.authorizeHttpRequests(a -> a
                .requestMatchers("/", "/healthz", "/readyz", "/error", "/login-error").permitAll()
                .requestMatchers("/slo", "/slo/**").denyAll()
                .requestMatchers("/admin", "/admin/**").hasAuthority("APPROLE_hr-admins")
                .anyRequest().authenticated())
            .oauth2Login(o -> o
                .loginPage("/oauth2/authorization/entra")
                .failureHandler((request, response, exception) -> {
                    var code = exception instanceof org.springframework.security.oauth2.core.OAuth2AuthenticationException oauth
                        ? oauth.getError().getErrorCode() : "authentication_failed";
                    log.warn("Entra sign-in failed ({})", code);
                    request.getSession().setAttribute("entraLoginError", code);
                    response.sendRedirect("/login-error");
                })
                .authorizationEndpoint(a -> a.authorizationRequestResolver(authorization))
                .userInfoEndpoint(u -> u.oidcUserService(users).userAuthoritiesMapper(granted -> {
                    var mapped = new HashSet<GrantedAuthority>(granted);
                    for (var authority : granted) {
                        if (authority instanceof OidcUserAuthority oidc) {
                            var roles = oidc.getIdToken().getClaimAsStringList("roles");
                            if (roles != null) roles.forEach(role ->
                                mapped.add(new SimpleGrantedAuthority("APPROLE_" + role)));
                        }
                    }
                    return mapped;
                })))
            .logout(l -> l.logoutRequestMatcher(new AntPathRequestMatcher("/logout", "POST"))
                .deleteCookies("JSESSIONID").logoutSuccessHandler(logout))
            .build();
    }
}
