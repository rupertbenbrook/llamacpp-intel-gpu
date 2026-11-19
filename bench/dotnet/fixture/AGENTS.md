# Agent verification requirements

Before finishing any task:

1. Inspect the actual files you changed and keep the public API and existing behavior intact.
2. Run `dotnet build AgentBench.slnx --nologo -v q` from the solution root.
3. If the build fails, read the compiler output, fix the cause, and run the build again. Do not claim success while it fails.
4. For Dockerfile tasks, inspect the Dockerfile and make the smallest correct fix. Run the .NET build, but do not run Docker commands yourself; the external verifier builds and runs the image. The application must listen on `0.0.0.0` inside the container; `127.0.0.1` is not reachable through a published port.
5. Do not modify tests, verifier files, or this instruction file.
