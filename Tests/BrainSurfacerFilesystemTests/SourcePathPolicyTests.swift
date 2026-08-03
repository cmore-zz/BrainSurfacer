import BrainSurfacerFilesystem
import Testing

@Test
func sourcePathPolicyMatchesRootRelativeGlobsWithExclusionsTakingPriority() {
    let policy = SourcePathPolicy(
        includePatterns: [" **/*.md ", "Projects/**/*.org", "Projects/**/*.org"],
        excludePatterns: ["**/Archive/**", "Private?.md", "Drafts/"]
    )

    #expect(policy.includePatterns == ["**/*.md", "Projects/**/*.org"])
    #expect(policy.excludePatterns == ["**/Archive/**", "Private?.md", "Drafts/**"])
    #expect(policy.includes(relativePath: "Root.md"))
    #expect(policy.includes(relativePath: "Nested/Note.md"))
    #expect(policy.includes(relativePath: "Projects/Plan.org"))
    #expect(policy.includes(relativePath: "Projects/Nested/Plan.org"))
    #expect(!policy.includes(relativePath: "Elsewhere/Plan.org"))
    #expect(!policy.includes(relativePath: "Nested/Archive/Old.md"))
    #expect(!policy.includes(relativePath: "Private1.md"))
    #expect(policy.includes(relativePath: "Private10.md"))
    #expect(!policy.includes(relativePath: "Drafts/Idea.md"))
}

@Test
func unrestrictedSourcePathPolicyIncludesEveryNonemptyRelativePath() {
    let policy = SourcePathPolicy()

    #expect(policy.isUnrestricted)
    #expect(policy.includes(relativePath: "Note.md"))
    #expect(policy.includes(relativePath: "Nested/Plan.org"))
    #expect(!policy.includes(relativePath: ""))
}

@Test
func rootDirectoryPatternsNormalizeToTheCanonicalRecursiveGlob() {
    let policy = SourcePathPolicy(
        includePatterns: ["/", "./", "**", "**/"],
        excludePatterns: [" Archive/ "]
    )

    #expect(policy.includePatterns == ["**"])
    #expect(policy.excludePatterns == ["Archive/**"])
    #expect(policy.includes(relativePath: "Nested/Note.md"))
}
