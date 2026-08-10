defmodule ScxmlEngine.EventMatcherTest do
  use ExUnit.Case, async: true

  alias ScxmlEngine.EventMatcher

  describe "match?/2" do
    test "wildcard matches anything" do
      assert EventMatcher.match?("*", "anything")
      assert EventMatcher.match?("*", "a.b.c")
    end

    test "exact match" do
      assert EventMatcher.match?("user.login", "user.login")
      refute EventMatcher.match?("user.login", "user.logout")
    end

    test "dot-prefix pattern matches prefix and descendants" do
      assert EventMatcher.match?("user.*", "user.login")
      assert EventMatcher.match?("user.*", "user")
      assert EventMatcher.match?("user.*", "user.profile.update")
      refute EventMatcher.match?("user.*", "admin.login")
      refute EventMatcher.match?("user.*", "usercard")
    end

    test "tokenized (space-separated) pattern matches if any token matches" do
      assert EventMatcher.match?("done.state.a done.state.b", "done.state.b")
      assert EventMatcher.match?("done.state.a done.state.b", "done.state.a")
      refute EventMatcher.match?("done.state.a done.state.b", "done.state.c")
    end

    test "nil pattern does not match an event" do
      refute EventMatcher.match?(nil, "anything")
    end
  end
end
