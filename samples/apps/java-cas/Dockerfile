FROM maven:3.9.9-eclipse-temurin-21 AS build
WORKDIR /work
COPY pom.xml .
COPY src src
RUN mvn -B -DskipTests package
FROM eclipse-temurin:21-jre-jammy
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates gosu && rm -rf /var/lib/apt/lists/* && useradd --uid 10001 --create-home hr
WORKDIR /app
COPY --from=build /work/target/hr-self-service-1.0.0.jar app.jar
COPY start.sh .
RUN sed -i 's/\r$//' start.sh && chmod +x start.sh && chown -R hr /app
EXPOSE 8080
ENTRYPOINT ["/app/start.sh"]
