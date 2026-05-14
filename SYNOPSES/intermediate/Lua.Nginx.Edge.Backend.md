# Lua Nginx Edge Backend

## Overview
Build a complete CRUD application backend running entirely through Lua embedded in Nginx using OpenResty, with zero traditional application servers. Authentication with JWT validation, rate limiting, request validation, database queries via PostgreSQL, response caching, and input filtering all happen at the Nginx edge layer in Lua. This project teaches the power of edge computing for API backends and why companies like Cloudflare, Kong, and Amazon CloudFront invest heavily in edge logic. You will learn that the boundary between "web server" and "application server" is artificial — Nginx with Lua can be both.

## Step-by-Step Instructions
1. **Set up the OpenResty environment and project structure** Install OpenResty (the Nginx + LuaJIT bundle) and configure the project directory structure with separate directories for Lua modules, Nginx configuration, database migrations, and tests. Configure `nginx.conf` to load Lua modules from your project directory using `lua_package_path`. Set up a development workflow where Nginx reloads configuration on file changes (use `openresty -s reload` triggered by a file watcher). Create a base `init_by_lua_block` that loads shared configuration and initializes connection pools. Verify the setup by serving a simple JSON response from a `content_by_lua_block`.

2. **Implement PostgreSQL database access via pgmoon** Install and configure `pgmoon` (the pure Lua PostgreSQL driver) to connect to PostgreSQL from within Nginx. Implement connection pooling using `ngx.socket.tcp` keepalive to reuse database connections across requests. Build a database access module that provides parameterized query execution (preventing SQL injection), result parsing into Lua tables, and transaction support. Create database migrations for a sample application schema: users table, resources table (the CRUD target), and an audit log table. Test connection pooling by verifying that connections are reused and the pool size stays bounded under load.

3. **Build the CRUD API endpoints** Implement full CRUD operations for a resource entity: `POST /api/resources` (create), `GET /api/resources` (list with pagination), `GET /api/resources/:id` (read single), `PUT /api/resources/:id` (update), and `DELETE /api/resources/:id` (delete). Use `content_by_lua_block` in each Nginx location block to handle the request. Parse request bodies with `cjson`, validate input parameters, execute database queries via pgmoon, and return JSON responses with appropriate HTTP status codes. Implement pagination using cursor-based pagination (more efficient than OFFSET for large datasets). Handle errors gracefully with structured error responses.

4. **Implement JWT authentication at the edge** Build a JWT validation module in Lua that runs in `access_by_lua_block` before any request reaches the content handler. Parse the Authorization header, decode the JWT (using `lua-resty-jwt` or implement from scratch with `lua-resty-string` for HMAC-SHA256), validate the signature, check expiration and issuer claims, and extract the user identity. Store the authenticated user in `ngx.ctx` so content handlers can access it. Implement token refresh endpoints and build a user registration/login flow that issues JWTs. Reject unauthenticated requests with 401 and unauthorized requests with 403.

5. **Add rate limiting and request throttling** Implement rate limiting using `lua-resty-limit-traffic` with three strategies: per-IP rate limiting (using `ngx.shared.DICT` for shared memory across Nginx workers), per-user rate limiting (based on the authenticated JWT subject), and per-endpoint rate limiting (different limits for read vs write operations). Configure the shared memory zones in `nginx.conf`. Return proper 429 responses with `Retry-After` headers. Implement a sliding window algorithm rather than fixed windows to prevent burst abuse at window boundaries. Add rate limit headers to all responses (`X-RateLimit-Limit`, `X-RateLimit-Remaining`, `X-RateLimit-Reset`).

6. **Build input validation and security filtering** Create a request validation module that runs in `access_by_lua_block` to validate all incoming data before it reaches the content handler. Implement JSON schema validation for request bodies, URL parameter type checking and range validation, and header validation. Build an input filtering layer that detects and blocks SQL injection attempts, XSS payloads, path traversal sequences, and oversized request bodies. Use `ngx.re.match` with PCRE patterns for efficient regex matching. Log all blocked requests to a separate security log file with the blocked payload and the rule that triggered.

7. **Implement response caching and performance optimization** Build a caching layer using `lua-resty-lrucache` for in-worker caching and `ngx.shared.DICT` for cross-worker caching. Cache GET responses with configurable TTLs per endpoint. Implement cache invalidation on write operations (POST, PUT, DELETE should invalidate related cache entries). Add ETag support: generate ETags from response content hashes and handle `If-None-Match` headers to return 304 Not Modified when appropriate. Implement response compression with `gzip` for JSON responses. Benchmark the application with and without caching using `wrk` to measure the performance improvement.

8. **Add logging, monitoring, and deployment packaging** Implement structured JSON logging in `log_by_lua_block` that records: request method, path, status code, response time, authenticated user, rate limit state, cache hit/miss, and database query count. Send logs to stdout for container deployment compatibility. Build a `/healthz` endpoint that checks database connectivity and returns service status. Create a Docker Compose setup with OpenResty and PostgreSQL. Write a comprehensive test suite using `Test::Nginx` (the OpenResty test framework) or `curl`-based integration tests that verify all CRUD operations, authentication flows, rate limiting behavior, and cache correctness.

## Key Concepts to Learn
- OpenResty architecture and Nginx Lua module phases
- Edge computing for API backends and the web server/app server convergence
- Connection pooling and shared memory in Nginx worker processes
- JWT authentication implementation at the edge layer
- Rate limiting algorithms: sliding window vs fixed window vs token bucket
- Input validation and security filtering at the edge
- Response caching strategies and cache invalidation patterns
- Lua programming patterns for high-performance request handling

## Deliverables
- OpenResty-based CRUD API with zero application servers
- PostgreSQL integration via pgmoon with connection pooling
- JWT authentication module running in Nginx access phase
- Three-strategy rate limiting system with shared memory
- Input validation and security filtering middleware
- Response caching with ETag support and cache invalidation
- Docker Compose deployment with structured JSON logging
