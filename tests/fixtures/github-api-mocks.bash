#!/bin/bash

# GitHub API Mock System für deterministische Tests
# Dieses Modul mockt alle GitHub API calls und CLI commands
# für isolierte und zuverlässige Tests

# ===============================================================================
# MOCK CONFIGURATION
# ===============================================================================

# Mock responses directory
export GITHUB_MOCK_RESPONSES_DIR="${BATS_TEST_DIRNAME}/fixtures/github-responses"

# Ensure mock responses directory exists
mkdir -p "$GITHUB_MOCK_RESPONSES_DIR"

# Mock state tracking
declare -A GITHUB_MOCK_API_CALLS
declare -A GITHUB_MOCK_AUTH_STATE
declare -A GITHUB_MOCK_RATE_LIMITS

# ===============================================================================
# MOCK GITHUB CLI (gh) COMMANDS
# ===============================================================================

mock_gh() {
    local subcommand="$1"
    shift
    
    # Track API calls
    local call_key="${subcommand}_$(echo "$@" | tr ' ' '_')"
    GITHUB_MOCK_API_CALLS["$call_key"]=$((${GITHUB_MOCK_API_CALLS["$call_key"]:-0} + 1))
    
    case "$subcommand" in
        "auth")
            mock_gh_auth "$@"
            ;;
        "api")
            mock_gh_api "$@"
            ;;
        "issue")
            mock_gh_issue "$@"
            ;;
        "pr")
            mock_gh_pr "$@"
            ;;
        "repo")
            mock_gh_repo "$@"
            ;;
        "--version")
            echo "gh version 2.32.1 (2023-07-18)"
            return 0
            ;;
        *)
            echo "Mock gh: unknown subcommand '$subcommand'" >&2
            return 1
            ;;
    esac
}

mock_gh_auth() {
    local auth_cmd="$1"
    shift
    
    case "$auth_cmd" in
        "status")
            if [[ "${GITHUB_MOCK_AUTH_STATE[authenticated]:-false}" == "true" ]]; then
                echo "✓ Logged in to github.com as ${GITHUB_MOCK_AUTH_STATE[username]:-testuser} (~/path/to/config.yml)"
                echo "✓ Git operations for github.com configured to use https protocol."
                echo "✓ Token: gho_************************************"
                return 0
            else
                echo "You are not logged into any GitHub hosts. Run gh auth login to authenticate."
                return 1
            fi
            ;;
        "token")
            if [[ "${GITHUB_MOCK_AUTH_STATE[authenticated]:-false}" == "true" ]]; then
                echo "gho_1234567890abcdef1234567890abcdef12345678"
                return 0
            else
                echo "authentication required" >&2
                return 1
            fi
            ;;
        *)
            echo "Mock gh auth: unknown command '$auth_cmd'" >&2
            return 1
            ;;
    esac
}

mock_gh_api() {
    local endpoint="$1"
    shift
    
    # Parse common API options
    local method="GET"
    local headers=()
    local data=""
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            "-X"|"--method")
                method="$2"
                shift 2
                ;;
            "-H"|"--header")
                headers+=("$2")
                shift 2
                ;;
            "-f"|"--field"|"--raw-field")
                data="$2"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done
    
    # Simulate rate limiting
    local current_limit=${GITHUB_MOCK_RATE_LIMITS[remaining]:-5000}
    if [[ $current_limit -le 0 ]]; then
        echo '{"message":"API rate limit exceeded","documentation_url":"https://docs.github.com/rest/overview/resources-in-the-rest-api#rate-limiting"}' >&2
        return 1
    fi
    GITHUB_MOCK_RATE_LIMITS[remaining]=$((current_limit - 1))
    
    case "$endpoint" in
        "/user")
            cat << 'EOF'
{
  "login": "testuser",
  "id": 12345,
  "name": "Test User",
  "email": "test@example.com",
  "public_repos": 42,
  "private_repos": 7
}
EOF
            ;;
        "/repos/"*)
            mock_gh_api_repo_endpoint "$endpoint" "$method"
            ;;
        "/rate_limit")
            cat << EOF
{
  "resources": {
    "core": {
      "limit": 5000,
      "remaining": ${GITHUB_MOCK_RATE_LIMITS[remaining]:-5000},
      "reset": $(date -d '+1 hour' +%s),
      "used": $((5000 - ${GITHUB_MOCK_RATE_LIMITS[remaining]:-5000}))
    }
  }
}
EOF
            ;;
        *)
            echo "Mock API: unknown endpoint '$endpoint'" >&2
            return 1
            ;;
    esac
}

mock_gh_api_repo_endpoint() {
    local endpoint="$1"
    local method="$2"
    
    # Extract repo info from endpoint
    if [[ "$endpoint" =~ ^/repos/([^/]+)/([^/]+)(/.*)?$ ]]; then
        local owner="${BASH_REMATCH[1]}"
        local repo="${BASH_REMATCH[2]}"
        local path="${BASH_REMATCH[3]:-}"
        
        case "$path" in
            "")
                # Repository info
                cat << EOF
{
  "id": 12345678,
  "name": "$repo",
  "full_name": "$owner/$repo",
  "owner": {
    "login": "$owner",
    "id": 123456
  },
  "private": false,
  "description": "Test repository for mocking",
  "default_branch": "main",
  "permissions": {
    "admin": true,
    "maintain": true,
    "push": true,
    "triage": true,
    "pull": true
  }
}
EOF
                ;;
            "/issues/"*)
                if [[ "$path" =~ ^/issues/([0-9]+)(/.*)?$ ]]; then
                    local issue_number="${BASH_REMATCH[1]}"
                    local issue_path="${BASH_REMATCH[2]:-}"
                    
                    case "$issue_path" in
                        "")
                            mock_github_issue_response "$owner" "$repo" "$issue_number"
                            ;;
                        "/comments")
                            mock_github_issue_comments_response "$owner" "$repo" "$issue_number" "$method"
                            ;;
                        *)
                            echo "Mock API: unknown issue path '$issue_path'" >&2
                            return 1
                            ;;
                    esac
                else
                    echo "Mock API: invalid issue endpoint '$path'" >&2
                    return 1
                fi
                ;;
            "/pulls/"*)
                if [[ "$path" =~ ^/pulls/([0-9]+)(/.*)?$ ]]; then
                    local pr_number="${BASH_REMATCH[1]}"
                    local pr_path="${BASH_REMATCH[2]:-}"
                    
                    case "$pr_path" in
                        "")
                            mock_github_pr_response "$owner" "$repo" "$pr_number"
                            ;;
                        "/comments")
                            mock_github_pr_comments_response "$owner" "$repo" "$pr_number" "$method"
                            ;;
                        *)
                            echo "Mock API: unknown PR path '$pr_path'" >&2
                            return 1
                            ;;
                    esac
                else
                    echo "Mock API: invalid PR endpoint '$path'" >&2
                    return 1
                fi
                ;;
            *)
                echo "Mock API: unknown repo path '$path'" >&2
                return 1
                ;;
        esac
    else
        echo "Mock API: invalid repo endpoint '$endpoint'" >&2
        return 1
    fi
}

# ===============================================================================
# MOCK RESPONSE GENERATORS
# ===============================================================================

mock_github_issue_response() {
    local owner="$1"
    local repo="$2"
    local issue_number="$3"
    
    cat << EOF
{
  "id": $((123456789 + issue_number)),
  "number": $issue_number,
  "title": "Test Issue #$issue_number",
  "body": "This is a test issue for mocking purposes.\n\n**Priority**: High\n**Type**: Bug\n\n- [x] Reproduce the issue\n- [ ] Fix the bug\n- [ ] Add tests",
  "state": "open",
  "user": {
    "login": "$owner",
    "id": 123456
  },
  "assignee": null,
  "assignees": [],
  "milestone": null,
  "labels": [
    {
      "name": "bug",
      "color": "d73a49"
    },
    {
      "name": "priority: high",
      "color": "b60205"
    }
  ],
  "created_at": "$(date -u -Iseconds)",
  "updated_at": "$(date -u -Iseconds)",
  "closed_at": null,
  "html_url": "https://github.com/$owner/$repo/issues/$issue_number",
  "url": "https://api.github.com/repos/$owner/$repo/issues/$issue_number",
  "repository_url": "https://api.github.com/repos/$owner/$repo",
  "comments": 3,
  "reactions": {
    "total_count": 5,
    "+1": 3,
    "-1": 0,
    "laugh": 1,
    "hooray": 1,
    "confused": 0,
    "heart": 0,
    "rocket": 0,
    "eyes": 0
  }
}
EOF
}

mock_github_pr_response() {
    local owner="$1"
    local repo="$2"
    local pr_number="$3"
    
    cat << EOF
{
  "id": $((987654321 + pr_number)),
  "number": $pr_number,
  "title": "Test Pull Request #$pr_number",
  "body": "This is a test PR for mocking purposes.\n\n## Changes\n- Added new feature X\n- Fixed bug Y\n- Improved test coverage\n\n## Testing\n- [x] Unit tests pass\n- [x] Integration tests pass\n- [ ] Manual testing completed",
  "state": "open",
  "user": {
    "login": "$owner",
    "id": 123456
  },
  "head": {
    "ref": "feature/test-pr-$pr_number",
    "sha": "abc123def456789012345678901234567890abcd"
  },
  "base": {
    "ref": "main",
    "sha": "def456abc123456789012345678901234567890ef"
  },
  "draft": false,
  "mergeable": true,
  "mergeable_state": "clean",
  "merged": false,
  "merge_commit_sha": null,
  "created_at": "$(date -u -Iseconds)",
  "updated_at": "$(date -u -Iseconds)",
  "closed_at": null,
  "merged_at": null,
  "html_url": "https://github.com/$owner/$repo/pull/$pr_number",
  "url": "https://api.github.com/repos/$owner/$repo/pulls/$pr_number",
  "repository_url": "https://api.github.com/repos/$owner/$repo",
  "comments": 7,
  "review_comments": 12,
  "commits": 5,
  "additions": 142,
  "deletions": 38,
  "changed_files": 8
}
EOF
}

mock_github_issue_comments_response() {
    local owner="$1"
    local repo="$2"
    local issue_number="$3"
    local method="$4"
    
    case "$method" in
        "GET")
            cat << EOF
[
  {
    "id": 1234567890,
    "body": "Great issue! I'll work on this.",
    "user": {
      "login": "contributor1",
      "id": 789012
    },
    "created_at": "$(date -u -d '2 hours ago' -Iseconds)",
    "updated_at": "$(date -u -d '2 hours ago' -Iseconds)",
    "html_url": "https://github.com/$owner/$repo/issues/$issue_number#issuecomment-1234567890"
  },
  {
    "id": 1234567891,
    "body": "🤖 **Task Progress Update**\n\n**Status**: In Progress\n**Progress**: 65%\n\n---\n\n<details>\n<summary>📊 Progress Details</summary>\n\n### Completed Tasks\n- ✅ Task 1: Analysis completed\n- ✅ Task 2: Implementation started\n- 🔄 Task 3: Testing in progress\n- ⏳ Task 4: Documentation pending\n\n### Next Steps\n- Complete testing phase\n- Update documentation\n- Final review\n\n</details>\n\n---\n\n*Last updated: $(date -u -Iseconds)*",
    "user": {
      "login": "claude-bot",
      "id": 987654
    },
    "created_at": "$(date -u -d '1 hour ago' -Iseconds)",
    "updated_at": "$(date -u -d '30 minutes ago' -Iseconds)",
    "html_url": "https://github.com/$owner/$repo/issues/$issue_number#issuecomment-1234567891"
  }
]
EOF
            ;;
        "POST")
            # Simulate posting a new comment
            local new_comment_id=$((1234567890 + RANDOM))
            cat << EOF
{
  "id": $new_comment_id,
  "body": "[Mock comment posted successfully]",
  "user": {
    "login": "testuser",
    "id": 123456
  },
  "created_at": "$(date -u -Iseconds)",
  "updated_at": "$(date -u -Iseconds)",
  "html_url": "https://github.com/$owner/$repo/issues/$issue_number#issuecomment-$new_comment_id"
}
EOF
            ;;
        *)
            echo "Mock API: unsupported method '$method' for comments" >&2
            return 1
            ;;
    esac
}

mock_github_pr_comments_response() {
    local owner="$1"
    local repo="$2"
    local pr_number="$3"
    local method="$4"
    
    case "$method" in
        "GET")
            cat << EOF
[
  {
    "id": 2345678901,
    "body": "The implementation looks good, but please add more tests.",
    "user": {
      "login": "reviewer1",
      "id": 345678
    },
    "created_at": "$(date -u -d '3 hours ago' -Iseconds)",
    "updated_at": "$(date -u -d '3 hours ago' -Iseconds)",
    "html_url": "https://github.com/$owner/$repo/pull/$pr_number#issuecomment-2345678901"
  }
]
EOF
            ;;
        "POST")
            # Simulate posting a new comment
            local new_comment_id=$((2345678901 + RANDOM))
            cat << EOF
{
  "id": $new_comment_id,
  "body": "[Mock PR comment posted successfully]",
  "user": {
    "login": "testuser",
    "id": 123456
  },
  "created_at": "$(date -u -Iseconds)",
  "updated_at": "$(date -u -Iseconds)",
  "html_url": "https://github.com/$owner/$repo/pull/$pr_number#issuecomment-$new_comment_id"
}
EOF
            ;;
        *)
            echo "Mock API: unsupported method '$method' for PR comments" >&2
            return 1
            ;;
    esac
}

# ===============================================================================
# MOCK CONTROL FUNCTIONS
# ===============================================================================

set_github_mock_auth_state() {
    local authenticated="$1"
    local username="${2:-testuser}"
    
    GITHUB_MOCK_AUTH_STATE[authenticated]="$authenticated"
    GITHUB_MOCK_AUTH_STATE[username]="$username"
}

set_github_mock_rate_limit() {
    local remaining="$1"
    local reset_timestamp="${2:-$(($(date +%s) + 3600))}"
    
    GITHUB_MOCK_RATE_LIMITS[remaining]="$remaining"
    GITHUB_MOCK_RATE_LIMITS[reset]="$reset_timestamp"
}

simulate_github_api_error() {
    local error_type="$1"
    
    case "$error_type" in
        "rate_limit")
            GITHUB_MOCK_RATE_LIMITS[remaining]=0
            ;;
        "auth_failure")
            GITHUB_MOCK_AUTH_STATE[authenticated]=false
            ;;
        "network_error")
            # This would be handled by the calling test
            return 1
            ;;
        *)
            echo "Unknown error type: $error_type" >&2
            return 1
            ;;
    esac
}

reset_github_mock_state() {
    unset GITHUB_MOCK_API_CALLS
    unset GITHUB_MOCK_AUTH_STATE
    unset GITHUB_MOCK_RATE_LIMITS
    
    declare -gA GITHUB_MOCK_API_CALLS
    declare -gA GITHUB_MOCK_AUTH_STATE
    declare -gA GITHUB_MOCK_RATE_LIMITS
    
    # Set default state
    set_github_mock_auth_state "true" "testuser"
    set_github_mock_rate_limit "5000"
}

get_github_mock_api_call_count() {
    local call_pattern="$1"
    local total=0
    
    for call_key in "${!GITHUB_MOCK_API_CALLS[@]}"; do
        if [[ "$call_key" =~ $call_pattern ]]; then
            total=$((total + GITHUB_MOCK_API_CALLS["$call_key"]))
        fi
    done
    
    echo "$total"
}

# ===============================================================================
# MOCK INITIALIZATION
# ===============================================================================

# Initialize mock state
reset_github_mock_state

# Export mock functions
export -f mock_gh
export -f mock_gh_auth
export -f mock_gh_api
export -f mock_gh_api_repo_endpoint
export -f mock_github_issue_response
export -f mock_github_pr_response
export -f mock_github_issue_comments_response
export -f mock_github_pr_comments_response
export -f set_github_mock_auth_state
export -f set_github_mock_rate_limit
export -f simulate_github_api_error
export -f reset_github_mock_state
export -f get_github_mock_api_call_count