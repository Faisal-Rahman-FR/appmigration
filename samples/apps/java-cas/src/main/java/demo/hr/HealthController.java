package demo.hr;

import org.springframework.beans.factory.annotation.Value;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;
import java.util.Map;

@RestController
public class HealthController {
    private static final Logger log = LoggerFactory.getLogger(HealthController.class);
    @Value("${demo.readiness-uri}") private String readinessUri;
    private final HttpClient client = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(3)).build();
    @GetMapping("/healthz")
    Map<String,String> health() { return Map.of("status", "ok"); }
    @GetMapping("/readyz")
    ResponseEntity<Map<String,String>> ready() {
        try {
            var response = client.send(HttpRequest.newBuilder(URI.create(readinessUri)).timeout(Duration.ofSeconds(5)).GET().build(), HttpResponse.BodyHandlers.discarding());
            if (response.statusCode() == 200) return ResponseEntity.ok(Map.of("status", "ready"));
            log.warn("Identity provider readiness returned HTTP {}", response.statusCode());
        } catch (InterruptedException exception) {
            Thread.currentThread().interrupt();
        } catch (java.io.IOException exception) {
            log.warn("Identity provider readiness request failed: {}", exception.getClass().getSimpleName());
        }
        return ResponseEntity.status(503).body(Map.of("status", "notReady"));
    }
}
