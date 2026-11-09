FROM gradle:8.14-jdk21 AS build
WORKDIR /work
COPY build.gradle settings.gradle ./
COPY src src
RUN gradle --no-daemon bootWar
FROM eclipse-temurin:21-jre-jammy
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates gosu && rm -rf /var/lib/apt/lists/*
COPY --from=build /work/build/libs/cas.war /app/cas.war
COPY start.sh /app/start.sh
RUN sed -i 's/\r$//' /app/start.sh && chmod +x /app/start.sh && useradd --uid 10001 --create-home cas && chown -R cas /app
EXPOSE 8080
ENTRYPOINT ["/app/start.sh"]
