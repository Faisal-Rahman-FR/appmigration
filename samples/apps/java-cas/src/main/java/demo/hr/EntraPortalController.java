package demo.hr;

import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.core.oidc.user.OidcUser;
import org.springframework.stereotype.Controller;
import org.springframework.ui.Model;
import org.springframework.web.bind.annotation.GetMapping;

@Controller
@ConditionalOnProperty(name = "demo.auth", havingValue = "entra")
public class EntraPortalController {
    @GetMapping("/login-error")
    @org.springframework.web.bind.annotation.ResponseStatus(org.springframework.http.HttpStatus.UNAUTHORIZED)
    String loginError(jakarta.servlet.http.HttpSession session, Model model) {
        model.addAttribute("reason", session.getAttribute("entraLoginError"));
        return "login-error";
    }

    @GetMapping("/")
    String home(Model model) {
        model.addAttribute("entra", true);
        return "home";
    }

    @GetMapping("/login")
    String login() { return "redirect:/profile"; }

    @GetMapping("/profile")
    String profile(@AuthenticationPrincipal OidcUser user, Model model) {
        model.addAttribute("identity", EntraUserService.identity(user));
        return "profile";
    }

    @GetMapping("/admin")
    String admin(@AuthenticationPrincipal OidcUser user, Model model) {
        model.addAttribute("identity", EntraUserService.identity(user));
        model.addAttribute("entra", true);
        return "admin";
    }
}
