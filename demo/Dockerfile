FROM alpine:latest

# 第 2 层：模拟 JRE 与依赖库。体量大，但 v1 -> v1.0.1 之间完全不变。
COPY assets/deps.bin /opt/deps/deps.bin

# 第 3 层：应用 jar。每次发版只改这一层。
ARG JAR=assets/app-v1.jar
COPY ${JAR} /app/app.jar

# 用于验证重建后的镜像里装的确实是目标版本
CMD ["/bin/sh", "-c", "sha256sum /app/app.jar"]
