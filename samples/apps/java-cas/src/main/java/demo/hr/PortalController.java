package demo.hr;

import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpSession;
import org.apereo.cas.client.util.AbstractCasFilter;
import org.apereo.cas.client.validation.Assertion;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Controller;
import org.springframework.ui.Model;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.server.ResponseStatusException;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.UUID;

@Controller
@ConditionalOnProperty(name = "demo.auth", havingValue = "cas", matchIfMissing = true)
public class PortalController {
    @Value("${demo.cas-origin}") private String cas;
    @Value("${demo.app-origin}") private String origin;

    private Identity identity(HttpSession session) {
        var assertion = (Assertion) session.getAttribute(AbstractCasFilter.CONST_CAS_ASSERTION);
        if (assertion == null) throw new ResponseStatusException(HttpStatus.UNAUTHORIZED);
        return new Identity(assertion.getPrincipal().getName(), assertion.getPrincipal().getAttributes());
    }
    @GetMapping("/")
    String home() { return "home"; }
    @GetMapping("/login")
    String login() { return "redirect:/profile"; }
    @GetMapping("/profile")
    String profile(HttpSession session, Model model) {
        model.addAttribute("identity", identity(session));
        if (session.getAttribute("csrf") == null) session.setAttribute("csrf", UUID.randomUUID().toString());
        model.addAttribute("csrf", session.getAttribute("csrf"));
        return "profile";
    }
    @GetMapping("/admin")
    String admin(HttpSession session, Model model) {
        var user = identity(session);
        if (!user.hrAdmin()) throw new ResponseStatusException(HttpStatus.FORBIDDEN);
        model.addAttribute("identity", user);
        return "admin";
    }
    @PostMapping("/logout")
    String logout(HttpServletRequest request, @RequestParam String csrf) {
        var session = request.getSession(false);
        if (session == null || !(session.getAttribute("csrf") instanceof String expected)
            || !MessageDigest.isEqual(expected.getBytes(StandardCharsets.UTF_8), csrf.getBytes(StandardCharsets.UTF_8))) {
            throw new ResponseStatusException(HttpStatus.FORBIDDEN);
        }
        session.invalidate();
        return "redirect:" + cas + "/cas/logout?service=" + URLEncoder.encode(origin + "/", StandardCharsets.UTF_8);
    }
    @PostMapping("/slo")
    org.springframework.http.ResponseEntity<Void> slo() {
        // The Apereo SingleSignOutFilter consumes valid back-channel logout requests first.
        return org.springframework.http.ResponseEntity.badRequest().build();
    }
}
