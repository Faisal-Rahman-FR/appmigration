package org.apereo.cas.config;

import org.apereo.cas.web.CasWebSecurityConfigurer;
import org.apereo.cas.web.demo.DemoHealthController;
import org.springframework.boot.autoconfigure.AutoConfiguration;
import org.springframework.boot.autoconfigure.condition.ConditionalOnMissingBean;
import org.springframework.context.annotation.Bean;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import java.util.List;

@AutoConfiguration
public class DemoHealthConfiguration {
    @Bean
    @ConditionalOnMissingBean(DemoHealthController.class)
    public DemoHealthController demoHealthController() {
        return new DemoHealthController();
    }

    @Bean
    public CasWebSecurityConfigurer<HttpSecurity> demoHealthSecurityConfigurer() {
        return new CasWebSecurityConfigurer<>() {
            @Override
            public List<String> getIgnoredEndpoints() {
                return List.of("/healthz", "/readyz");
            }
        };
    }
}
