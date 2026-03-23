/**
 * DOTBOT Control Panel - Error Log Module
 * Fetches, displays, and manages the structured error log
 */

let errorCurrentOffset = 0;
const ERROR_PAGE_SIZE = 50;

/**
 * Initialize the errors tab - attach event handlers
 */
function initErrors() {
    const refreshBtn = document.getElementById('errors-refresh-btn');
    const clearBtn = document.getElementById('errors-clear-btn');
    const filterLevel = document.getElementById('error-filter-level');
    const filterSource = document.getElementById('error-filter-source');

    if (refreshBtn) refreshBtn.addEventListener('click', () => { errorCurrentOffset = 0; fetchErrors(); });
    if (clearBtn) clearBtn.addEventListener('click', clearErrors);
    if (filterLevel) filterLevel.addEventListener('change', () => { errorCurrentOffset = 0; fetchErrors(); });
    if (filterSource) filterSource.addEventListener('change', () => { errorCurrentOffset = 0; fetchErrors(); });
}

/**
 * Fetch errors from the API with current filters
 */
async function fetchErrors() {
    const level = document.getElementById('error-filter-level')?.value || '';
    const source = document.getElementById('error-filter-source')?.value || '';

    let url = `${API_BASE}/api/logs?limit=${ERROR_PAGE_SIZE}&offset=${errorCurrentOffset}`;
    if (level) url += `&level=${encodeURIComponent(level)}`;
    if (source) url += `&source=${encodeURIComponent(source)}`;

    try {
        const response = await fetch(url);
        if (!response.ok) throw new Error(`HTTP ${response.status}`);
        const data = await response.json();

        if (data.success) {
            renderErrors(data.entries, data.total);
            renderErrorSummary(data.summary);
            updateErrorSidebar(data.summary);
            updateErrorBadge(data.summary.total);
        }
    } catch (error) {
        console.error('Failed to fetch errors:', error);
    }
}

/**
 * Render the error list
 */
function renderErrors(entries, total) {
    const container = document.getElementById('errors-list');
    if (!container) return;

    if (!entries || entries.length === 0) {
        container.innerHTML = '<div class="errors-placeholder">No errors recorded</div>';
        renderPagination(0, 0);
        return;
    }

    const VALID_LEVELS = { critical: 'critical', fatal: 'fatal', error: 'error', warning: 'warning', warn: 'warn', info: 'info', debug: 'debug' };

    container.innerHTML = entries.map(entry => {
        const ts = formatErrorTimestamp(entry.timestamp);
        const safeLevel = VALID_LEVELS[(entry.level || '').toLowerCase()] || 'error';
        const levelClass = `error-level-${safeLevel}`;
        const levelLabel = safeLevel.toUpperCase();
        const sourceLabel = escapeHtml(entry.source || 'unknown');
        const message = escapeHtml(entry.message || '');
        const taskId = entry.task_id ? `<span class="error-task-id">${escapeHtml(entry.task_id.substring(0, 8))}</span>` : '';
        const processType = entry.process_type ? `<span class="error-process-type">${escapeHtml(entry.process_type)}</span>` : '';
        const errorCode = entry.error_code ? `<span class="error-code">${escapeHtml(entry.error_code)}</span>` : '';
        const hasStack = entry.stack_trace ? ' has-stack' : '';
        const stackHtml = entry.stack_trace
            ? `<div class="error-stack hidden"><pre>${escapeHtml(entry.stack_trace)}</pre></div>`
            : '';

        return `<div class="error-entry${hasStack}" role="button" tabindex="0" aria-expanded="false" onclick="toggleErrorStack(this)" onkeydown="if(event.key==='Enter'||event.key===' '){event.preventDefault();toggleErrorStack(this)}">
            <div class="error-header">
                <span class="error-level ${levelClass}">${levelLabel}</span>
                <span class="error-source">${sourceLabel}</span>
                ${processType}
                ${taskId}
                ${errorCode}
                <span class="error-time">${ts}</span>
            </div>
            <div class="error-message">${message}</div>
            ${stackHtml}
        </div>`;
    }).join('');
    renderPagination(total, errorCurrentOffset);
}

/**
 * Toggle stack trace visibility
 */
function toggleErrorStack(el) {
    const stack = el.querySelector('.error-stack');
    if (stack) {
        stack.classList.toggle('hidden');
        el.setAttribute('aria-expanded', !stack.classList.contains('hidden'));
    }
}

/**
 * Render pagination controls
 */
function renderPagination(total, offset) {
    const container = document.getElementById('errors-pagination');
    if (!container) return;

    if (total <= ERROR_PAGE_SIZE) {
        container.innerHTML = total > 0 ? `<span class="errors-count">${total} error${total !== 1 ? 's' : ''}</span>` : '';
        return;
    }

    const currentPage = Math.floor(offset / ERROR_PAGE_SIZE) + 1;
    const totalPages = Math.ceil(total / ERROR_PAGE_SIZE);

    container.innerHTML = `
        <button class="ctrl-btn-xs" ${offset <= 0 ? 'disabled' : ''} onclick="errorPagePrev()">Prev</button>
        <span class="errors-count">Page ${currentPage} of ${totalPages} (${total} total)</span>
        <button class="ctrl-btn-xs" ${offset + ERROR_PAGE_SIZE >= total ? 'disabled' : ''} onclick="errorPageNext()">Next</button>
    `;
}

function errorPagePrev() {
    errorCurrentOffset = Math.max(0, errorCurrentOffset - ERROR_PAGE_SIZE);
    fetchErrors();
}

function errorPageNext() {
    errorCurrentOffset += ERROR_PAGE_SIZE;
    fetchErrors();
}

/**
 * Render the error summary bar
 */
function renderErrorSummary(summary) {
    const container = document.getElementById('errors-summary');
    if (!container || !summary) return;

    const parts = [];
    if (summary.by_level) {
        if (summary.by_level.critical) parts.push(`<span class="error-level error-level-critical">${summary.by_level.critical} critical</span>`);
        if (summary.by_level.error) parts.push(`<span class="error-level error-level-error">${summary.by_level.error} errors</span>`);
        if (summary.by_level.warning) parts.push(`<span class="error-level error-level-warning">${summary.by_level.warning} warnings</span>`);
    }

    container.innerHTML = parts.length > 0
        ? `<div class="errors-summary-bar">${parts.join(' ')}</div>`
        : '';
}

/**
 * Update the sidebar stats
 */
function updateErrorSidebar(summary) {
    if (!summary) return;
    setElementText('error-stat-total', summary.total || 0);
    setElementText('error-stat-critical', (summary.by_level && summary.by_level.fatal) || 0);
    setElementText('error-stat-error', (summary.by_level && summary.by_level.error) || 0);
    setElementText('error-stat-warning', (summary.by_level && summary.by_level.warn) || 0);
    setElementText('error-stat-info', (summary.by_level && summary.by_level.info) || 0);
    setElementText('error-stat-debug', (summary.by_level && summary.by_level.debug) || 0);

    // Source breakdown
    const sourcesEl = document.getElementById('error-sidebar-sources');
    if (sourcesEl && summary.by_source) {
        const sourceEntries = Object.entries(summary.by_source);
        if (sourceEntries.length > 0) {
            sourcesEl.innerHTML = '<div class="sidebar-subheader">By Source</div>' +
                sourceEntries.map(([src, count]) =>
                    `<div class="stat-row"><span class="stat-label">${escapeHtml(src)}</span><span class="stat-value">${count}</span></div>`
                ).join('');
        } else {
            sourcesEl.innerHTML = '';
        }
    }
}

/**
 * Update the error badge on the tab
 */
function updateErrorBadge(total) {
    const badge = document.getElementById('error-badge');
    if (!badge) return;

    if (total > 0) {
        badge.textContent = total > 999 ? '999+' : total;
        badge.classList.remove('hidden');
    } else {
        badge.classList.add('hidden');
    }
}

/**
 * Update error badge from state polling (called from ui-updates.js)
 */
function updateErrorBadgeFromState(state) {
    if (state && state.error_summary) {
        updateErrorBadge(state.error_summary.total || 0);
    }
}

/**
 * Clear all errors
 */
async function clearErrors() {
    if (!confirm('Clear all error log entries?')) return;

    try {
        const response = await fetch(`${API_BASE}/api/logs/clear`, { method: 'POST' });
        if (!response.ok) throw new Error(`HTTP ${response.status}`);
        const result = await response.json();
        if (result.success) {
            errorCurrentOffset = 0;
            fetchErrors();
            if (typeof showToast === 'function') showToast('Error log cleared', 'success', 4000);
        }
    } catch (error) {
        console.error('Failed to clear errors:', error);
        if (typeof showToast === 'function') showToast('Failed to clear error log', 'error', 5000);
    }
}

/**
 * Format timestamp for display
 */
function formatErrorTimestamp(isoString) {
    if (!isoString) return '';
    try {
        const date = new Date(isoString);
        const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
        const month = months[date.getMonth()];
        const day = date.getDate();
        const hours = date.getHours().toString().padStart(2, '0');
        const mins = date.getMinutes().toString().padStart(2, '0');
        const secs = date.getSeconds().toString().padStart(2, '0');
        return `${month} ${day} ${hours}:${mins}:${secs}`;
    } catch (e) {
        return '';
    }
}

/**
 * Called when errors tab becomes active
 */
function onErrorsTabActivated() {
    fetchErrors();
}
