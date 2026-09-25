defmodule YmerNode.McpTest do
  @moduledoc """
  Reads the mount's options back through `YmerNode.Mcp.init/1` — the wire values
  the server actually serves, not the source that produced them. No database and
  no listener: the mount freezes its options at compile time, so every assertion
  here is a pure read.

  The release-config case is the one exception: it reads `config/prod.exs` with
  `Config.Reader`, because a release's own defaults cannot be observed from an
  application booted in any other environment. Still a pure read — one file, no
  boot, no environment variables — so the module stays `async: true`.
  """
  use ExUnit.Case, async: true

  # Claude Code truncates server instructions and tool descriptions at 2KB
  # each — a cliff, not a warning.
  @mcp_text_budget 2048

  defp mount_opts, do: YmerNode.Mcp.init([])

  describe "the MCP mount" do
    test "instructions fit the 2KB client budget" do
      instructions = Keyword.fetch!(mount_opts(), :instructions)
      assert byte_size(instructions) <= @mcp_text_budget
    end

    @tag doc: """
         Guards the two-servers-one-product presentation: a client meeting this
         node must learn that ymer is the other half, because nothing else in
         the wire surface says so. A failure means the cross-reference paragraph
         was dropped or reworded past recognition — restore it rather than
         relaxing the assertion.
         """
    test "instructions name ymer as the other half of one product" do
      instructions = Keyword.fetch!(mount_opts(), :instructions)
      # Not a bare =~ "ymer": the offline paragraph mentions ymer too, so that
      # match cannot fail. This pins the cross-reference sentence itself, and
      # keeps "ymer" inside the pinned substring so a rewording that drops the
      # name goes red.
      assert instructions =~ "ymer are two halves of one product"
    end

    @tag doc: """
         Pins the bind default, which is a security control rather than a
         preference: `/mcp` is unauthenticated, so off-container the loopback bind
         is the only thing keeping an SQL surface off the LAN. A failure means the
         default moved, or a bind address was set across all environments — check
         `config/config.exs` before touching this. Why the node's own image widens
         it lives in `YmerNode.Mcp`'s "Loopback is the security model" section.
         """
    test "the bind address defaults to loopback" do
      assert YmerNode.Mcp.ip() == {127, 0, 0, 1}
    end

    @tag doc: """
         Pins one of the two conditions a bare `bin/ymer_node start` needs to bind
         loopback — that `config/prod.exs` carries no bind address — which no
         assertion against the running application can reach, because this
         environment's config is never the release's. A failure means the wide bind
         moved back into compile-time release config. The other condition, that
         `config/runtime.exs` widens only behind the bind marker, is
         `YmerNode.ReleaseConfigTest`'s; see `docs/glossary.md`'s *bind marker*
         entry for the term.
         """
    test "the release config carries no bind address of its own" do
      release_config =
        Config.Reader.read!(Path.expand("../../config/prod.exs", __DIR__), env: :prod)

      mcp = release_config |> Keyword.fetch!(:ymer_node) |> Keyword.fetch!(YmerNode.Mcp)

      assert Keyword.fetch!(mcp, :port) == 8012
      refute Keyword.has_key?(mcp, :ip)
    end

    test "every tool description fits the 2KB client budget" do
      tools = Keyword.fetch!(mount_opts(), :tools)

      # Without this the loop below passes vacuously on an empty list — the
      # budget guard would stop guarding without ever going red.
      assert tools != []

      for tool <- tools do
        assert byte_size(tool.description()) <= @mcp_text_budget,
               "#{tool.name()}: #{byte_size(tool.description())} bytes"
      end
    end

    @tag doc: """
         The mount's tool list is the node's whole external surface, and it is
         written out literally in `YmerNode.Mcp` so that the compile-time check
         validating each tool's schemas cannot go stale. A failure means a tool
         left the mount — a client would simply not see it, and nothing else in
         the suite would go red.
         """
    test "every capability is mounted" do
      names = mount_opts() |> Keyword.fetch!(:tools) |> Enum.map(& &1.name())

      # `help` is not declared at the mount: Wymcp appends it to every server
      # under that reserved name, so it is part of the surface a client meets
      # and belongs in an exact-list assertion.
      assert Enum.sort(names) ==
               ["help", "notebook", "references", "schedules", "script_author", "scripts"]
    end

    @tag doc: """
         The instructions are the only place a client learns what this node can
         do before it calls anything, so every capability has to be named there.
         A failure means one of them went invisible at connect: the tool still
         answers, but nothing tells a worker to reach for it.
         """
    test "the instructions name every capability" do
      instructions = Keyword.fetch!(mount_opts(), :instructions)

      assert instructions =~ "notebook"
      assert instructions =~ "references"
      assert instructions =~ "scripts"
      assert instructions =~ "script_author"
      assert instructions =~ "schedules"
    end

    @tag doc: """
         The guide is where a client learns to write a script, and the
         instructions are the one text every client reads before any call. A
         failure means the scripts bullet lost its pointer — a worker would
         write from the tool notes alone, which no longer carry the contract.
         """
    test "the instructions name the guide as the call before writing a script" do
      instructions = Keyword.fetch!(mount_opts(), :instructions)

      assert instructions =~ "scripts guide"
      assert instructions =~ "scripts info"
    end

    @tag doc: """
         The budget case above proves the text FITS; this one proves it is not
         fitting by having quietly shed a capability's paragraph. Together they
         are the trade the 2KB cliff forces: every capability named, inside
         2048 bytes. A failure here with the budget case green means a bullet
         was cut to make room, and the fix is to shorten prose rather than to
         drop a tool from the list.
         """
    test "the instructions still have room to say more" do
      instructions = Keyword.fetch!(mount_opts(), :instructions)

      assert byte_size(instructions) > 1900,
             "the instructions shrank; check that no capability's bullet was dropped"
    end
  end
end
