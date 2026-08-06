defmodule MCP.ElicitationTest do
  use ExUnit.Case, async: true

  import MCP.Elicitation, only: [form: 2]

  describe "form/2 with declared fields" do
    test "builds the restricted requestedSchema the spec allows" do
      request =
        form "Pick one" do
          field :size, :string, enum: ["s", "m"], description: "Shirt size", required: true
          field :count, :integer
        end

      assert request == %{
               "method" => "elicitation/create",
               "params" => %{
                 "mode" => "form",
                 "message" => "Pick one",
                 "requestedSchema" => %{
                   "type" => "object",
                   "properties" => %{
                     "size" => %{
                       "type" => "string",
                       "enum" => ["s", "m"],
                       "description" => "Shirt size"
                     },
                     "count" => %{"type" => "integer"}
                   },
                   "required" => ["size"]
                 }
               }
             }
    end

    test "omits required entirely when no field declares it" do
      request =
        form "Optional" do
          field :note, :string
        end

      refute Map.has_key?(request["params"]["requestedSchema"], "required")
    end

    # A tool input default replaces required; here it is a form prefill.
    test "a default combines with required rather than replacing it" do
      request =
        form "Confirm" do
          field :agree, :boolean, required: true, default: false
        end

      schema = request["params"]["requestedSchema"]

      assert schema["properties"]["agree"]["default"] == false
      assert schema["required"] == ["agree"]
    end

    test "emits the string hints under their spec-cased keys" do
      request =
        form "About you" do
          field :email, :string, title: "Email", format: :email, min_length: 3, max_length: 254
        end

      assert request["params"]["requestedSchema"]["properties"]["email"] == %{
               "type" => "string",
               "title" => "Email",
               "format" => "email",
               "minLength" => 3,
               "maxLength" => 254
             }
    end

    test "emits the numeric bounds" do
      request =
        form "How old" do
          field :age, :integer, minimum: 18, maximum: 120
        end

      assert request["params"]["requestedSchema"]["properties"]["age"] == %{
               "type" => "integer",
               "minimum" => 18,
               "maximum" => 120
             }
    end
  end

  describe "form/2 compile-time checks" do
    test "rejects a type outside the primitive subset" do
      assert error("field :tags, :array") =~ "must be one of"
    end

    # The spec gives each primitive its own key set; a wrong-type option is a bug.
    test "rejects an option the declared type does not allow" do
      assert error("field :count, :integer, format: :email") =~ "is not allowed on :integer"
    end

    test "rejects an unknown field option" do
      assert error("field :name, :string, bogus: 1") =~ "is not allowed on :string"
    end

    test "rejects anything but field calls inside the block" do
      assert error(~s|IO.puts("side effect")|) =~ "takes only `field name, type, opts`"
    end
  end

  test "rejects an unrecognized format at runtime" do
    assert_raise ArgumentError, ~r/invalid MCP.Elicitation format/, fn ->
      MCP.Elicitation.__field__(:name, :string, format: :phone)
    end
  end

  test "form_schema/2 accepts a raw schema as an escape hatch" do
    schema = %{
      "type" => "object",
      "properties" => %{
        "size" => %{"type" => "string", "oneOf" => [%{"const" => "s", "title" => "Small"}]}
      }
    }

    assert MCP.Elicitation.form_schema("Raw", schema)["params"]["requestedSchema"] == schema
  end

  test "url/2 builds the out-of-band mode" do
    assert MCP.Elicitation.url("Log in", "https://example.test/oauth") == %{
             "method" => "elicitation/create",
             "params" => %{
               "mode" => "url",
               "message" => "Log in",
               "url" => "https://example.test/oauth"
             }
           }
  end

  # Expansion-time raises can surface wrapped, so compare messages not structs.
  defp error(body) do
    Code.eval_string("""
    import MCP.Elicitation, only: [form: 2]

    form "Nope" do
      #{body}
    end
    """)

    flunk("expected #{inspect(body)} to be rejected")
  rescue
    error in [ExUnit.AssertionError] -> reraise(error, __STACKTRACE__)
    error -> Exception.message(error)
  end
end
