# Test activation's exit status when it can't write /etc entries: an entry it
# may replace but can't (a non-empty directory in the way) fails the
# activation, which still writes the profile's other entries and leaves the
# directory alone; once the path is free, the same profile activates. An
# unmanaged file at an entry without replaceExisting is left alone.
{
  forEachDistro,
  system-manager,
  system,
  ...
}:

let
  entries = {
    environment.etc = {
      # replaceExisting: a file in the way is backed up, but a non-empty
      # directory can't be.
      "etc-failures/blocked.conf" = {
        text = "managed blocked\n";
        replaceExisting = true;
      };
      "etc-failures/other.conf".text = "managed other\n";
    };
  };

  # The same entries, and two without replaceExisting, one linked, one copied.
  unmanagedToplevel = system-manager.lib.makeSystemConfig {
    modules = [
      {
        nixpkgs.hostPlatform = system;
        system-manager.allowAnyDistro = true;
      }
      entries
      {
        environment.etc = {
          "etc-failures/unmanaged-link.conf".text = "managed link\n";
          "etc-failures/unmanaged-copy.conf" = {
            text = "managed copy\n";
            mode = "0644";
          };
        };
      }
    ];
  };
in
forEachDistro "etc-activation-failures" {
  modules = [ entries ];
  extraPathsToRegister = [ unmanagedToplevel ];
  testScriptFunction =
    { toplevel, ... }:
    ''
      start_all()
      machine.wait_for_unit("multi-user.target")

      # An unmanaged file at an entry without replaceExisting is a warning:
      # the entry isn't applied, and the activation still exits 0.
      UNMANAGED_FILE_EXIT = 0

      def activate(profile: str, expected: int) -> str:
          res = machine.execute(f"{profile}/bin/activate 2>&1")
          assert res.returncode == expected, f"Expected exit {expected}, got {res.returncode}:\n{res.stdout}"
          return res.stdout

      def content(path: str) -> str:
          return machine.succeed(f"cat {path}")

      with subtest("a non-empty directory at a managed target fails the activation"):
          machine.succeed("mkdir -p /etc/etc-failures/blocked.conf")
          machine.succeed("echo theirs > /etc/etc-failures/blocked.conf/keep")
          out = activate("${toplevel}", 1)
          errors = [line for line in out.splitlines() if "Failed to create" in line]
          assert errors, out
          assert "/etc/etc-failures/blocked.conf" in errors[-1], out
          # The directory is left alone.
          machine.succeed("test -d /etc/etc-failures/blocked.conf")
          assert content("/etc/etc-failures/blocked.conf/keep") == "theirs\n"
          # The profile's other entries are written.
          assert content("/etc/etc-failures/other.conf") == "managed other\n"

      with subtest("once the path is free, the same profile activates"):
          machine.succeed("rm -r /etc/etc-failures/blocked.conf")
          activate("${toplevel}", 0)
          machine.succeed("test -L /etc/etc-failures/blocked.conf")
          assert content("/etc/etc-failures/blocked.conf") == "managed blocked\n"
          machine.fail("test -e /etc/etc-failures/blocked.conf.system-manager-backup")

      with subtest("an unmanaged file at an entry without replaceExisting is left alone"):
          machine.succeed("echo theirs > /etc/etc-failures/unmanaged-link.conf")
          machine.succeed("echo theirs > /etc/etc-failures/unmanaged-copy.conf")
          out = activate("${unmanagedToplevel}", UNMANAGED_FILE_EXIT)
          assert "Unmanaged path already exists in filesystem, please remove it and run system-manager again: /etc/etc-failures/unmanaged-link.conf" in out, out
          assert "File /etc/etc-failures/unmanaged-copy.conf already exists, ignoring" in out, out
          for name in ["unmanaged-link.conf", "unmanaged-copy.conf"]:
              assert content(f"/etc/etc-failures/{name}") == "theirs\n", name
              machine.fail(f"test -L /etc/etc-failures/{name}")
              machine.fail(f"test -e /etc/etc-failures/{name}.system-manager-backup")
          # The other entries are still applied.
          assert content("/etc/etc-failures/blocked.conf") == "managed blocked\n"

      with subtest("deactivating leaves the unmanaged files"):
          machine.succeed("${unmanagedToplevel}/bin/deactivate")
          machine.fail("test -e /etc/etc-failures/blocked.conf")
          machine.fail("test -e /etc/etc-failures/other.conf")
          for name in ["unmanaged-link.conf", "unmanaged-copy.conf"]:
              assert content(f"/etc/etc-failures/{name}") == "theirs\n", name
    '';
}
