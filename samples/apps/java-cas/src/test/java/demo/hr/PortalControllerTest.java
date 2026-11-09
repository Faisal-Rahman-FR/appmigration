package demo.hr;

import org.apereo.cas.client.authentication.AttributePrincipalImpl;
import org.apereo.cas.client.util.AbstractCasFilter;
import org.apereo.cas.client.validation.AssertionImpl;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.mock.web.MockHttpSession;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;
import org.springframework.web.servlet.view.RedirectView;
import org.springframework.web.servlet.view.json.MappingJackson2JsonView;
import java.util.Map;
import static org.junit.jupiter.api.Assertions.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

class PortalControllerTest {
    private MockMvc mvc;
    @BeforeEach void setup() {
        var controller = new PortalController();
        ReflectionTestUtils.setField(controller, "cas", "https://cas.demo.test");
        ReflectionTestUtils.setField(controller, "origin", "https://hr.demo.test");
        mvc = MockMvcBuilders.standaloneSetup(controller)
            .setViewResolvers((name,locale) -> name.startsWith("redirect:")
                ? new RedirectView(name.substring("redirect:".length()))
                : new MappingJackson2JsonView()).build();
    }
    private MockHttpSession session(Map<String,Object> attributes) {
        var session = new MockHttpSession();
        session.setAttribute(AbstractCasFilter.CONST_CAS_ASSERTION,
            new AssertionImpl(new AttributePrincipalImpl("alice", attributes)));
        return session;
    }
    @Test void adminRequiresExactReleasedGroup() throws Exception {
        mvc.perform(get("/admin").session(session(Map.of()))).andExpect(status().isForbidden());
        mvc.perform(get("/admin").session(session(Map.of("memberOf", "cn=hr-admins,ou=groups,dc=demo,dc=test"))))
            .andExpect(status().isOk()).andExpect(view().name("admin"));
    }
    @Test void logoutRejectsCsrfAndInvalidatesValidSession() throws Exception {
        var invalid = session(Map.of());
        invalid.setAttribute("csrf", "valid");
        mvc.perform(post("/logout").session(invalid).param("csrf", "wrong")).andExpect(status().isForbidden());
        assertFalse(invalid.isInvalid());
        var valid = session(Map.of());
        valid.setAttribute("csrf", "valid");
        mvc.perform(post("/logout").session(valid).param("csrf", "valid"))
            .andExpect(status().is3xxRedirection())
            .andExpect(redirectedUrl("https://cas.demo.test/cas/logout?service=https%3A%2F%2Fhr.demo.test%2F"));
        assertTrue(valid.isInvalid());
    }
}
