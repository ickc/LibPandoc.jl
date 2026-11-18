# What a wasm filter sees of this process's environment (included in
# runtests.jl's testset).
# What a wasm filter sees of this process's environment: the example filter
# `conversion` reports the names it sees, and the values of those named
# LIBPANDOC_TEST_... (the variables set with `withenv`, or in a child's
# environment).
const ENV_OWN = ["PANDOC_INPUT_FORMAT", "PANDOC_OUTPUT_FORMAT", "PANDOC_READER_OPTIONS",
       "PANDOC_SANDBOX", "PANDOC_VERSION", "PANDOC_WRITER_OPTIONS"]
env_told(f; options...) = JSON.parse(JSON.parse(P.convert("x"; to = "json", filters = [f], options...))["blocks"][end]["c"][2])
function env_seen(f; options...)
    t = env_told(f; options...)
    @test all(n -> count(==(n), t["env"]) == 1, ENV_OWN)
    (String[n for n in t["env"] if !(n in ENV_OWN)], Dict{String, Any}(t["test-env"]))
end
# A name as an error shows it: up to an `=`, quoted.
env_quoted(name) = repr(occursin('=', name) ? first(split(name, '='; limit = 2)) * "=..." : name)
# What the conversion failed with (nothing if it didn't).
env_failure(f) = try
    env_told(f)
    nothing
catch e
    e isa FilterError ? sprint(showerror, e.exception) : rethrow()
end
const TEST_ENV = ("LIBPANDOC_WASM_ENV" => nothing, "LIBPANDOC_TEST_MISSING" => nothing, "LIBPANDOC_TEST_A" => "a",
            "LIBPANDOC_TEST_B" => "b", "LIBPANDOC_TEST_SECRET" => "canary")

@testset "a wasm filter's environment" begin
    if isempty(WASM)
        @info "a wasm filter's environment: set LIBPANDOC_WASM_FILTERS to test it"
    else
        conversion = wasm("conversion")
        none = (String[], Dict{String, Any}())
        withenv(TEST_ENV...) do
            # by default, none of the process's variables: the host's own only
            t = env_told(conversion)
            @test (t["env"], t["test-env"]) == (ENV_OWN, Dict())
            @test env_seen(WasmFilter(conversion)) == none
            # by name: the process's values when it runs; one it lacks left out
            f = WasmFilter(conversion; env = ["LIBPANDOC_TEST_A", "LIBPANDOC_TEST_MISSING"])
            withenv("LIBPANDOC_TEST_A" => "when it runs") do
                @test env_seen(f) == (["LIBPANDOC_TEST_A"], Dict("LIBPANDOC_TEST_A" => "when it runs"))
            end
            # with values
            for env in (Dict("LIBPANDOC_TEST_B" => "given", "LIBPANDOC_TEST_C" => "c"),
                        ["LIBPANDOC_TEST_B" => "given", "LIBPANDOC_TEST_C" => "c"])
                @test env_seen(WasmFilter(conversion; env)) ==
                      (["LIBPANDOC_TEST_B", "LIBPANDOC_TEST_C"], Dict("LIBPANDOC_TEST_B" => "given", "LIBPANDOC_TEST_C" => "c"))
            end
            @test env_seen(WasmFilter(conversion; env = ["LIBPANDOC_TEST_C" => "c", "LIBPANDOC_TEST_C" => "again"]))[2] ==
                  Dict("LIBPANDOC_TEST_C" => "again")
            # the variable, read when it runs: several names, empty entries
            # skipped, one the process lacks left out; a program's own replace it
            f = WasmFilter(conversion)
            withenv("LIBPANDOC_WASM_ENV" => ",LIBPANDOC_TEST_A,,LIBPANDOC_TEST_MISSING,LIBPANDOC_TEST_B,LIBPANDOC_TEST_A,") do
                both = (["LIBPANDOC_TEST_A", "LIBPANDOC_TEST_B"], Dict("LIBPANDOC_TEST_A" => "a", "LIBPANDOC_TEST_B" => "b"))
                @test env_seen(f) == both
                @test env_seen(conversion) == both
                for env in (String[], [], Dict())
                    @test env_seen(WasmFilter(conversion; env)) == none
                end
                @test env_seen(WasmFilter(conversion; env = ["LIBPANDOC_TEST_SECRET"]))[2] == Dict("LIBPANDOC_TEST_SECRET" => "canary")
                @test env_seen(WasmFilter(conversion; env = Dict("LIBPANDOC_TEST_C" => "c")))[2] == Dict("LIBPANDOC_TEST_C" => "c")
            end
            # the host's own win
            withenv("PANDOC_SANDBOX" => "yes", "PANDOC_VERSION" => "0") do
                for f in (WasmFilter(conversion; env = Dict("PANDOC_VERSION" => "0", "PANDOC_SANDBOX" => "yes")),
                          WasmFilter(conversion; env = ["PANDOC_SANDBOX"]), conversion)
                    t = withenv(() -> env_told(f), "LIBPANDOC_WASM_ENV" => "PANDOC_SANDBOX,PANDOC_VERSION")
                    @test (t["pandoc-version"], t["sandbox"], t["env"]) == (P._version_string(), "false", ENV_OWN)
                end
            end
            # what can't be a name: in the variable an error when the filter
            # runs; given by a program an ArgumentError when it is made, naming
            # it; never showing a value
            for (entry, bad) in (("LIBPANDOC_TEST_A,A B", "A B"), (" LIBPANDOC_TEST_A", " LIBPANDOC_TEST_A"),
                                 ("A\tB", "A\tB"), ("LIBPANDOC_TEST_A=canary,B", "LIBPANDOC_TEST_A=canary"),
                                 ("=canary", "=canary"))
                msg = withenv(() -> env_failure(conversion), "LIBPANDOC_WASM_ENV" => entry)
                @test msg == "LIBPANDOC_WASM_ENV: not a variable's name: $(env_quoted(bad))"
            end
            @test env_quoted("A B") == "\"A B\"" && env_quoted("TOKEN=canary") == "\"TOKEN=...\""
            for name in ("A B", "", "A\0B", "\ua0", "LIBPANDOC_TEST_A=canary"), env in ([name], Dict(name => "canary"))
                e = refused_with(() -> WasmFilter(conversion; env))
                @test e isa ArgumentError && e.msg == "$conversion: not a variable's name: $(env_quoted(name))"
            end
            e = refused_with(() -> WasmFilter(conversion; env = Dict("LIBPANDOC_TEST_C" => "can\0ary")))
            @test e isa ArgumentError && e.msg == "$conversion: LIBPANDOC_TEST_C: its value has a NUL"
            for env in ("LIBPANDOC_TEST_A", Dict("LIBPANDOC_TEST_A" => 1), [:LIBPANDOC_TEST_A])
                e = refused_with(() -> WasmFilter(conversion; env))
                @test e isa ArgumentError && !contains(e.msg, "LIBPANDOC_TEST_A")
            end
            # a value that isn't UTF-8 (POSIX's bytes)
            if !Sys.iswindows()
                withenv("LIBPANDOC_TEST_BAD" => "canary\xff") do
                    @test env_failure(WasmFilter(conversion; env = ["LIBPANDOC_TEST_BAD"])) ==
                          "$conversion: LIBPANDOC_TEST_BAD: its value is not UTF-8"
                    @test withenv(() -> env_failure(conversion), "LIBPANDOC_WASM_ENV" => "LIBPANDOC_TEST_BAD") ==
                          "LIBPANDOC_WASM_ENV: LIBPANDOC_TEST_BAD: its value is not UTF-8"
                end
            end
        end
        # pandocjl: the variables LIBPANDOC_WASM_ENV names, no other; a bad
        # entry fails (status 83), never showing a value
        child_env(names) = Dict("LIBPANDOC_WASM_ENV" => names, "LIBPANDOC_TEST_A" => "a",
                          "LIBPANDOC_TEST_SECRET" => "canary", "PANDOC_VERSION" => "0")
        told_by(out) = JSON.parse(JSON.parse(out)["blocks"][end]["c"][2])
        status, out, err = pandocjl("-t", "json", "-F", conversion; input = "x", env = child_env(""))
        @test status == 0 && told_by(out)["test-env"] == Dict() && all(in(ENV_OWN), told_by(out)["env"])
        status, out, err = pandocjl("-t", "json", "-F", conversion; input = "x",
                                    env = child_env("LIBPANDOC_TEST_A,,LIBPANDOC_TEST_MISSING,PANDOC_VERSION"))
        @test status == 0 && told_by(out)["test-env"] == Dict("LIBPANDOC_TEST_A" => "a")
        @test told_by(out)["pandoc-version"] == P._version_string()
        for (names, bad) in (("LIBPANDOC_TEST_A,A B", "\"A B\""), ("LIBPANDOC_TEST_SECRET=canary", "\"LIBPANDOC_TEST_SECRET=...\""))
            status, out, err = pandocjl("-t", "json", "-F", conversion; input = "x", env = child_env(names))
            @test status == 83 && contains(err, "LIBPANDOC_WASM_ENV: not a variable's name: $bad") && !contains(out * err, "canary")
        end
    end
end
