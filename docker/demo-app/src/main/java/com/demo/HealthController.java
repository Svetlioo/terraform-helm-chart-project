package com.demo;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.Map;

@RestController
public class HealthController {

    @Value("${app.environment:unknown}")
    private String environment;

    @Value("${app.version:1.0.0}")
    private String version;

    @GetMapping("/")
    public Map<String, String> root() {
        return Map.of(
            "service", "java-app",
            "environment", environment,
            "version", version,
            "status", "running"
        );
    }

    @GetMapping("/api/info")
    public Map<String, String> info() {
        return Map.of(
            "environment", environment,
            "version", version
        );
    }
}
