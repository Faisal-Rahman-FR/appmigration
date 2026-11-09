package demo.hr;

import jakarta.servlet.Filter;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.apereo.cas.client.authentication.AuthenticationFilter;
import org.apereo.cas.client.session.SingleSignOutFilter;
import org.apereo.cas.client.session.SingleSignOutHttpSessionListener;
import org.apereo.cas.client.validation.Cas30ProxyReceivingTicketValidationFilter;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.web.servlet.FilterRegistrationBean;
import org.springframework.boot.web.servlet.ServletListenerRegistrationBean;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.web.servlet.config.annotation.CorsRegistry;
import org.springframework.web.servlet.config.annotation.WebMvcConfigurer;
import java.util.Map;

@Configuration
@ConditionalOnProperty(name = "demo.auth", havingValue = "cas", matchIfMissing = true)
public class CasConfiguration implements WebMvcConfigurer {
    @Value("${demo.cas-origin}") private String cas;
    @Value("${demo.app-origin}") private String app;

    private <T extends Filter> FilterRegistrationBean<T> filter(T filter, int order, Map<String, String> params, String... paths) {
        var bean = new FilterRegistrationBean<>(filter);
        bean.setOrder(order);
        bean.setInitParameters(params);
        bean.addUrlPatterns(paths);
        return bean;
    }

    @Bean
    FilterRegistrationBean<Filter> logoutBoundary() {
        return filter((request, response, chain) -> {
            var http = (HttpServletRequest) request;
            if (http.getParameter("logoutRequest") != null && !http.getRequestURI().equals("/slo")) {
                ((HttpServletResponse) response).sendError(403);
                return;
            }
            chain.doFilter(request, response);
        }, -1, Map.of(), "/*");
    }

    @Bean
    FilterRegistrationBean<SingleSignOutFilter> singleLogout() {
        return filter(new SingleSignOutFilter(), 0, Map.of("casServerUrlPrefix", cas + "/cas"), "/*");
    }

    @Bean
    ServletListenerRegistrationBean<SingleSignOutHttpSessionListener> logoutListener() {
        return new ServletListenerRegistrationBean<>(new SingleSignOutHttpSessionListener());
    }

    @Bean
    FilterRegistrationBean<AuthenticationFilter> authentication() {
        return filter(new AuthenticationFilter(), 1, Map.of("casServerLoginUrl", cas + "/cas/login", "serverName", app), "/login", "/profile", "/admin");
    }

    @Bean
    FilterRegistrationBean<Cas30ProxyReceivingTicketValidationFilter> validation() {
        return filter(new Cas30ProxyReceivingTicketValidationFilter(), 2,
            Map.of("casServerUrlPrefix", cas + "/cas", "serverName", app, "redirectAfterValidation", "true", "useSession", "true"),
            "/login", "/profile", "/admin");
    }

    @Override
    public void addCorsMappings(CorsRegistry registry) {
        registry.addMapping("/healthz").allowedOrigins(app).allowedMethods("GET");
    }
}
