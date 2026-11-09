package demo.hr;

import org.junit.jupiter.api.Test;
import org.springframework.mock.web.MockFilterChain;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.mock.web.MockHttpServletResponse;
import static org.junit.jupiter.api.Assertions.*;

class LogoutBoundaryTest {
    @Test void logoutPayloadCannotBypassProtectedCallbackPath() throws Exception {
        var request = new MockHttpServletRequest("POST", "/login");
        request.setParameter("logoutRequest", "<LogoutRequest/>");
        var response = new MockHttpServletResponse();
        var chain = new MockFilterChain();
        new CasConfiguration().logoutBoundary().getFilter().doFilter(request, response, chain);
        assertEquals(403, response.getStatus());
        assertNull(chain.getRequest());
    }
    @Test void dedicatedCallbackPassesToRealCasFilter() throws Exception {
        var request = new MockHttpServletRequest("POST", "/slo");
        request.setParameter("logoutRequest", "<LogoutRequest/>");
        var response = new MockHttpServletResponse();
        var chain = new MockFilterChain();
        new CasConfiguration().logoutBoundary().getFilter().doFilter(request, response, chain);
        assertSame(request, chain.getRequest());
    }
}
