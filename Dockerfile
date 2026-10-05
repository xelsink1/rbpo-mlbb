FROM mcr.microsoft.com/dotnet/sdk:10.0.401@sha256:e70cdb7f80b0348f5cb85f19a8f670fca061f033d57eed12fa003d58b0e06317 AS build
WORKDIR /source
COPY src/WiseDubs.Api/WiseDubs.Api.csproj src/WiseDubs.Api/packages.lock.json src/WiseDubs.Api/
RUN dotnet restore src/WiseDubs.Api/WiseDubs.Api.csproj --locked-mode
COPY src/WiseDubs.Api/Program.cs src/WiseDubs.Api/
RUN dotnet publish src/WiseDubs.Api/WiseDubs.Api.csproj --no-restore --configuration Release --output /publish

FROM mcr.microsoft.com/dotnet/aspnet:10.0.12@sha256:222759b391a1aaf241166672c8f99b2d4ada452e7b5319f3c6e8f265a37b5ad4 AS runtime
WORKDIR /app
COPY --from=build /publish .
ENV ASPNETCORE_HTTP_PORTS=8080 ASPNETCORE_ENVIRONMENT=Production
USER $APP_UID
EXPOSE 8080
ENTRYPOINT ["dotnet", "WiseDubs.Api.dll"]
