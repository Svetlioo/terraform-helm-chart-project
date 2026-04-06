# Multi-stage build for Spring Boot Java application
FROM eclipse-temurin:17-jdk-alpine AS build
WORKDIR /app
# In a real setup, copy your Maven/Gradle project and build here
# For demo: we expect a pre-built JAR to be provided
COPY app.jar app.jar

FROM eclipse-temurin:17-jre-alpine
WORKDIR /app
RUN addgroup -S appgroup && adduser -S appuser -G appgroup
COPY --from=build /app/app.jar app.jar
USER appuser
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s --retries=3 \
  CMD wget -qO- http://localhost:8080/actuator/health || exit 1
ENTRYPOINT ["java", "-jar", "app.jar"]
