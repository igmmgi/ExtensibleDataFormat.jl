using Documenter

# Add the parent directory to the load path so we can load the local package
push!(LOAD_PATH, dirname(@__DIR__))
using ExtensibleDataFormat

# Set up the documentation
makedocs(
  sitename="ExtensibleDataFormat.jl",
  format=Documenter.HTML(
    prettyurls=get(ENV, "CI", nothing) == "true",
    assets=String[],
  ),
  modules=[ExtensibleDataFormat],
  remotes=nothing,
  pages=[
    "Home" => "index.md",
    "API Reference" => "api.md",
  ],

  doctest=true,
  checkdocs=:exports,
)

deploydocs(;
    repo = "github.com/igmmgi/ExtensibleDataFormat.jl.git",
    versions = ["stable" => "v^", "v#.#", "dev" => "master"],
    push_preview = true,
)
