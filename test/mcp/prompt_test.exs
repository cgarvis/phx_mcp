defmodule MCP.PromptTest do
  use ExUnit.Case, async: true

  alias MCP.TestSupport.{ReviewPrompt, SecretPrompt}

  describe "the use macro" do
    test "defines the callbacks from the options" do
      assert ReviewPrompt.name() == "review"
      assert ReviewPrompt.scopes() == []
      assert SecretPrompt.scopes() == ["secret:read"]
    end

    test "accumulates declared arguments in order" do
      assert [{:code, code_opts}, {:tone, tone_opts}] = ReviewPrompt.__mcp_arguments__()
      assert code_opts[:required] == true
      assert tone_opts[:description] == "Review tone"
      assert SecretPrompt.__mcp_arguments__() == []
    end
  end

  describe "build_prompt_entries!/1" do
    test "builds spec-shaped payloads" do
      [entry] = MCP.Server.build_prompt_entries!([ReviewPrompt])

      assert entry.payload == %{
               "name" => "review",
               "description" => "Ask for a review",
               "arguments" => [
                 %{"name" => "code", "description" => "The code to review", "required" => true},
                 %{"name" => "tone", "description" => "Review tone"}
               ]
             }
    end

    test "omits the arguments key when a prompt declares none" do
      [entry] = MCP.Server.build_prompt_entries!([SecretPrompt])
      refute Map.has_key?(entry.payload, "arguments")
    end

    test "rejects duplicate prompt names" do
      assert_raise ArgumentError, ~r/duplicate MCP prompt names/, fn ->
        MCP.Server.build_prompt_entries!([ReviewPrompt, ReviewPrompt])
      end
    end
  end

  describe "generated struct" do
    test "the arguments DSL defines a struct on the prompt module" do
      assert %ReviewPrompt{code: "x", tone: "kind"} = %ReviewPrompt{code: "x"}
    end

    test "a prompt without an arguments block still gets a struct" do
      assert %SecretPrompt{} == struct!(SecretPrompt, %{})
    end

    test "required arguments are enforced when building the struct" do
      assert_raise ArgumentError, ~r/must also be given when building struct/, fn ->
        struct!(ReviewPrompt, %{tone: "curt"})
      end
    end
  end

  describe "defaults" do
    test "a default makes the argument optional, so it cannot also be required" do
      assert_raise ArgumentError, ~r/both required and defaulted/, fn ->
        MCP.Prompt.__argument__(:tone, :string, required: true, default: "kind")
      end
    end

    test "a default must be a string, since prompt arguments are strings" do
      assert_raise ArgumentError, ~r/prompt arguments are strings/, fn ->
        MCP.Prompt.__argument__(:tone, :string, default: 42)
      end
    end

    # The wire has no type slot, so offering a choice would be a lie.
    test "a type other than :string is rejected" do
      assert_raise ArgumentError, ~r/must be :string/, fn ->
        MCP.Prompt.__argument__(:count, :integer, [])
      end
    end

    # PromptArgument is {name, title, description, required} -- no default slot.
    test "the default is not advertised in the prompts/list payload" do
      [entry] = MCP.Server.build_prompt_entries!([ReviewPrompt])
      tone = Enum.find(entry.payload["arguments"], &(&1["name"] == "tone"))

      refute Map.has_key?(tone, "default")
    end
  end

  describe "validate_args/2" do
    test "returns the prompt struct, applying defaults to omitted arguments" do
      assert MCP.Prompt.validate_args(ReviewPrompt, %{"code" => "1+1"}) ==
               {:ok, %ReviewPrompt{code: "1+1", tone: "kind"}}
    end

    test "a supplied value wins over the default" do
      assert {:ok, %ReviewPrompt{tone: "blunt"}} =
               MCP.Prompt.validate_args(ReviewPrompt, %{"code" => "x", "tone" => "blunt"})
    end

    test "flags missing required arguments" do
      assert {:error, ["code is required"]} = MCP.Prompt.validate_args(ReviewPrompt, %{})
    end

    test "flags non-string values" do
      assert {:error, ["code must be a string"]} =
               MCP.Prompt.validate_args(ReviewPrompt, %{"code" => 42})
    end

    test "flags undeclared arguments" do
      assert {:error, [~s(unknown argument: "bogus")]} =
               MCP.Prompt.validate_args(ReviewPrompt, %{"code" => "x", "bogus" => "y"})
    end
  end
end
