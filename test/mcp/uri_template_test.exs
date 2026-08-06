defmodule MCP.URITemplateTest do
  use ExUnit.Case, async: true

  alias MCP.URITemplate

  test "matches a single variable and percent-decodes it" do
    t = URITemplate.compile!("app://items/{id}")

    assert URITemplate.match(t, "app://items/42") == {:ok, %{"id" => "42"}}
    assert URITemplate.match(t, "app://items/a%20b") == {:ok, %{"id" => "a b"}}
  end

  test "a variable never crosses a slash and never matches empty" do
    t = URITemplate.compile!("app://items/{id}")

    assert URITemplate.match(t, "app://items/1/2") == :nomatch
    assert URITemplate.match(t, "app://items/") == :nomatch
    assert URITemplate.match(t, "app://other/1") == :nomatch
  end

  # The slash check runs on the raw span, so %2F would smuggle one past it.
  test "a value that decodes to a slash or invalid UTF-8 does not match" do
    t = URITemplate.compile!("app://items/{id}")

    assert URITemplate.match(t, "app://items/a%2Fb") == :nomatch
    assert URITemplate.match(t, "app://items/%2F") == :nomatch
    assert URITemplate.match(t, "app://items/%FF") == :nomatch
  end

  test "matches multiple variables split by literals" do
    t = URITemplate.compile!("app://m/{a}/notes/{b}")

    assert URITemplate.match(t, "app://m/1/notes/2") == {:ok, %{"a" => "1", "b" => "2"}}
    assert URITemplate.match(t, "app://m/1/other/2") == :nomatch
  end

  test "greedy matching backtracks so trailing literals still match" do
    t = URITemplate.compile!("app://v{major}.{minor}")

    assert URITemplate.match(t, "app://v1.2.3") == {:ok, %{"major" => "1.2", "minor" => "3"}}
  end

  test "compile! rejects malformed or variable-free templates" do
    for bad <- [
          "app://items/{id",
          "app://items/{id!}",
          "app://items/{}",
          "app://{a}/{a}",
          "app://}{a}",
          "app://static"
        ] do
      assert_raise ArgumentError, fn -> URITemplate.compile!(bad) end
    end
  end
end
