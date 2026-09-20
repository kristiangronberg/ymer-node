defmodule YmerNode.Mcp.Tools.References.ValidateTest do
  @moduledoc """
  Pure value checks — no database, no framework — so `async: true`. The source
  vocabulary is read through `YmerNode.References.Sources.vocabulary/0`, which
  answers the three built-ins until script rows exist.
  """
  use ExUnit.Case, async: true

  alias YmerNode.Mcp.Tools.References.Validate

  describe "id/1" do
    test "accepts a positive integer and its string form, trimmed" do
      assert {:ok, 7} = Validate.id(7)
      assert {:ok, 7} = Validate.id("7")
      assert {:ok, 7} = Validate.id(" 7 ")
    end

    test "refuses everything else with one distinct atom" do
      for value <- [0, -1, "banana", "7x", "", nil, %{}] do
        assert {:error, :invalid_id} = Validate.id(value), "accepted #{inspect(value)}"
      end
    end
  end

  describe "optional_query/1" do
    test "nil is absent, not empty" do
      assert {:ok, nil} = Validate.optional_query(nil)
    end

    test "trims, and refuses a query that is only whitespace" do
      assert {:ok, "release"} = Validate.optional_query("  release  ")
      assert {:error, :empty_query} = Validate.optional_query("   ")
      assert {:error, :empty_query} = Validate.optional_query("")
      assert {:error, :empty_query} = Validate.optional_query(42)
    end
  end

  describe "tags/1" do
    test "accepts nil and a list of strings; refuses anything else" do
      assert {:ok, nil} = Validate.tags(nil)
      assert {:ok, []} = Validate.tags([])
      assert {:ok, ["a", "b"]} = Validate.tags(["a", "b"])

      assert {:error, :invalid_tags} = Validate.tags([1, 2])
      assert {:error, :invalid_tags} = Validate.tags(["a", 2])
      assert {:error, :invalid_tags} = Validate.tags("a")
    end
  end

  describe "source/2" do
    @tag doc: """
         A failure that shows an atom coming back means an atom conversion crept
         into `Validate.source/2`; the reason a source token stays a string is
         that function's own `@doc`.
         """
    test "accepts a token in the current vocabulary and returns it unchanged" do
      for built_in <- ["web", "file", "other"] do
        assert {:ok, ^built_in} = Validate.source(built_in, [])
      end
    end

    @tag doc: """
         The vocabulary comes from the declarations the caller passed, not from
         a read of its own. A failure here means `source/2` went back to the
         database — the second query per call that this seam exists to remove.
         """
    test "a declared script's name is in the vocabulary those declarations imply" do
      declarations = [%{name: "tracker", hosts: ["tracker.example.fi"], action: "issue"}]

      assert {:ok, "tracker"} = Validate.source("tracker", declarations)
      assert {:error, :invalid_source} = Validate.source("tracker", [])
    end

    test "nil is absent; an unknown token and a non-string are refused" do
      assert {:ok, nil} = Validate.source(nil, [])
      assert {:error, :invalid_source} = Validate.source("no-such-script", [])
      assert {:error, :invalid_source} = Validate.source(42, [])
    end
  end

  describe "some_criterion/3" do
    test "refuses a find with nothing to go on" do
      assert {:error, :empty_find} = Validate.some_criterion(nil, nil, nil)
      assert {:error, :empty_find} = Validate.some_criterion(nil, [], nil)
    end

    test "any one criterion is enough" do
      assert :ok = Validate.some_criterion("q", nil, nil)
      assert :ok = Validate.some_criterion(nil, ["tag"], nil)
      assert :ok = Validate.some_criterion(nil, nil, "web")
    end
  end

  describe "limit/1" do
    @tag doc: """
         A failure on the clamp leg means an over-max limit started erroring
         instead of clamping, and on the string leg that numeric strings stopped
         being accepted; why `Validate.limit/1` does both is its own `@doc`.
         """
    test "defaults, accepts numeric strings, and clamps over-max values" do
      assert {:ok, 50} = Validate.limit(nil)
      assert {:ok, 2} = Validate.limit(2)
      assert {:ok, 2} = Validate.limit("2")
      assert {:ok, 100} = Validate.limit(150)
      assert {:ok, 100} = Validate.limit("150")
    end

    test "refuses non-positive and unparseable limits" do
      for value <- [0, -1, "0", "banana", "2x", %{}] do
        assert {:error, :invalid_limit} = Validate.limit(value), "accepted #{inspect(value)}"
      end
    end
  end
end
