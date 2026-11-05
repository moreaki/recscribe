"""Historical identity discovery shared by the source audit and boundary guard.

Identity data stays in Git history. Do not copy retired product/contributor names
into current sources or encode them into a second identifier registry.
"""
from dataclasses import dataclass
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parent.parent
BASELINE = "2f9c42dd92dad72cb7e1d29ce555c2ee48967e53"


def git(*arguments):
    return subprocess.check_output(["git", *arguments], cwd=ROOT, stderr=subprocess.PIPE)


@dataclass(frozen=True)
class Identities:
    projects: tuple[str, ...]
    contributors: tuple[str, ...]
    other_identifiers: tuple[str, ...]

    def pattern(self):
        expressions = [re.escape(value) for value in self.contributors + self.other_identifiers]
        for name in self.projects:
            words = re.sub(r"(?<=[a-z0-9])(?=[A-Z])", " ", name).split()
            expressions.append(r"[ _.-]*".join(map(re.escape, words)))
        if not expressions:
            raise ValueError("Historical identity discovery returned no boundary markers")
        return re.compile("(?:" + "|".join(sorted(set(expressions))) + ")", re.I)


def identities():
    try:
        if git("rev-parse", "--is-shallow-repository").strip() != b"false":
            raise ValueError("Full Git history is required for historical identity discovery")
        names = git("ls-tree", "-r", "--name-only", BASELINE).decode().splitlines()
        projects = {part.removesuffix(".xcodeproj") for name in names for part in name.split("/")
                    if part.endswith(".xcodeproj")}
        if not projects:
            raise ValueError("Historical snapshot has no application project identity")
        folded = {re.sub(r"[^a-z0-9]", "", name.lower()) for name in projects}
        readme = git("show", BASELINE + ":README.md").decode()
        markers = set()
        for owner, repository in re.findall(r'https?://github\.com/([^/\s)<>]+)/([^/\s)<>#]+)', readme):
            repository = repository.removesuffix(".git")
            if re.sub(r"[^a-z0-9]", "", repository.lower()) in folded:
                markers.update((owner, repository))
                markers.update(part for part in re.split(r"[-_]", owner) if len(part) >= 5)
        namespace_owners = set()
        for name in names:
            if name.endswith(".xcodeproj/project.pbxproj"):
                project = git("show", BASELINE + ":" + name).decode()
                for identifier in re.findall(r"PRODUCT_BUNDLE_IDENTIFIER\s*=\s*([^;\r\n]+)", project):
                    parts = identifier.strip().strip('"').split(".")
                    markers.add(identifier.strip().strip('"'))
                    if len(parts) >= 3 and len(parts[1]) >= 4:
                        namespace_owners.add(parts[1])
        log = git("log", BASELINE, "--format=%an%x00%ae%x00%B%x00%x1e").decode()
        people = set()
        addresses = set()
        for record in log.split("\x1e"):
            fields = record.strip().split("\x00")
            if len(fields) < 3:
                continue
            author, address, message = fields[:3]
            people.add(author)
            addresses.add(address)
            for person, email in re.findall(r"(?im)^co-authored-by:\s*([^<\r\n]+?)\s*<([^>]+)>", message):
                people.add(person.strip())
                addresses.add(email)
        contributor_markers = set(people) | namespace_owners
        contributor_markers.update(person.split()[0] for person in people if person.split())
        for address in addresses:
            local, separator, domain = address.partition("@")
            if not separator:
                continue
            if len(local) >= 4 and local.lower() not in {"noreply", "no-reply", "notifications", "users"}:
                contributor_markers.add(local)
            organization = domain.split(".")[0]
            if len(organization) >= 4 and organization.lower() not in {"gmail", "hotmail", "outlook", "yahoo", "icloud", "users", "protonmail"}:
                contributor_markers.add(organization)
        snapshot_variables = subprocess.run(
            ["git", "grep", "-h", "-I", "-E", r'environment\["[A-Z][A-Z0-9_]*_SNAPSHOT"', BASELINE, "--", "*.swift"],
            cwd=ROOT, capture_output=True)
        if snapshot_variables.returncode not in (0, 1):
            raise ValueError("Cannot inspect historical environment identifiers")
        markers.update(re.findall(r'environment\["([A-Z][A-Z0-9_]*_SNAPSHOT)"', snapshot_variables.stdout.decode()))
        if not people or not markers:
            raise ValueError("Historical contributor/repository discovery is incomplete")
        return Identities(tuple(sorted(projects)), tuple(sorted(contributor_markers)), tuple(sorted(markers)))
    except subprocess.CalledProcessError as error:
        raise ValueError("Historical baseline unavailable; use a checkout with full Git history") from error
