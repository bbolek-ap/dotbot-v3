/**
 * DOTBOT Control Panel - Utility Functions
 * Generic utility functions used across modules
 */

/**
 * Escape HTML special characters to prevent XSS
 * @param {string} text - Text to escape
 * @returns {string} Escaped text
 */
function escapeHtml(text) {
    if (!text) return '';
    const div = document.createElement('div');
    div.textContent = text;
    return div.innerHTML;
}

/**
 * Set text content of element by ID
 * @param {string} id - Element ID
 * @param {string|number} text - Text to set
 */
function setElementText(id, text) {
    const el = document.getElementById(id);
    if (el) el.textContent = text;
}

/**
 * Format ISO date string to compact display format
 * @param {string} isoString - ISO date string
 * @returns {string} Formatted date like "Jan 15 14:30"
 */
function formatCompactDate(isoString) {
    if (!isoString) return '';
    try {
        const date = new Date(isoString);
        const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
        const month = months[date.getMonth()];
        const day = date.getDate();
        const hours = date.getHours().toString().padStart(2, '0');
        const mins = date.getMinutes().toString().padStart(2, '0');
        return `${month} ${day} ${hours}:${mins}`;
    } catch (e) {
        return '';
    }
}

/**
 * Format ISO date string to human-friendly format with day of week
 * @param {string} isoString - ISO date string
 * @returns {string} Formatted date like "Fri Dec 15 14:30"
 */
function formatFriendlyDate(isoString) {
    if (!isoString) return '';
    try {
        const date = new Date(isoString);
        const days = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
        const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
        const dayOfWeek = days[date.getDay()];
        const month = months[date.getMonth()];
        const dayNum = date.getDate();
        const hours = date.getHours().toString().padStart(2, '0');
        const mins = date.getMinutes().toString().padStart(2, '0');
        return `${dayOfWeek} ${month} ${dayNum} ${hours}:${mins}`;
    } catch (e) {
        return '';
    }
}

/**
 * Format ISO date string to time only
 * @param {string} isoString - ISO date string
 * @returns {string} Formatted time like "14:30:45"
 */
function formatCompactTime(isoString) {
    if (!isoString) return '';
    try {
        const date = new Date(isoString);
        const hours = date.getHours().toString().padStart(2, '0');
        const mins = date.getMinutes().toString().padStart(2, '0');
        const secs = date.getSeconds().toString().padStart(2, '0');
        return `${hours}:${mins}:${secs}`;
    } catch (e) {
        return '';
    }
}

/**
 * Truncate a message to max length with ellipsis
 * @param {string} message - Message to truncate
 * @param {number} maxLen - Maximum length
 * @returns {string} Truncated message
 */
function truncateMessage(message, maxLen) {
    if (!message) return '';
    if (message.length <= maxLen) return message;
    return message.substring(0, maxLen) + '…';
}

/**
 * Get CSS class for activity type
 * @param {string} type - Activity type
 * @returns {string} CSS class name
 */
function getActivityTypeClass(type) {
    if (!type) return 'activity-other';
    const t = type.toLowerCase();
    if (t === 'read') return 'activity-read';
    if (t === 'write') return 'activity-write';
    if (t === 'edit') return 'activity-edit';
    if (t === 'bash') return 'activity-bash';
    if (t === 'glob' || t === 'grep') return 'activity-search';
    if (t === 'text') return 'activity-text';
    if (t === 'done') return 'activity-done';
    if (t === 'init') return 'activity-init';
    if (t.startsWith('mcp__')) return 'activity-mcp';
    return 'activity-other';
}

/**
 * Get icon for activity type
 * @param {string} type - Activity type
 * @returns {string} Icon character
 */
function getActivityIcon(type) {
    if (!type) return '•';
    const t = type.toLowerCase();
    if (t === 'read') return '◇';
    if (t === 'write') return '◆';
    if (t === 'edit') return '✎';
    if (t === 'bash') return '▶';
    if (t === 'glob' || t === 'grep') return '⌕';
    if (t === 'text') return '¶';
    if (t === 'done') return '✓';
    if (t === 'init') return '⚡';
    if (t.startsWith('mcp__') || t.startsWith('mcp_')) return '⚙';
    if (t === 'task') return '☐';
    return '•';
}

/**
 * Format activity entry for display
 * For MCP tools: type becomes "Tool", message becomes the tool name
 * For others: type and message stay as-is
 * @param {Object} entry - Activity entry with type and message
 * @returns {Object} { displayType, displayMessage }
 */
function formatActivityEntry(entry) {
    const type = entry.type || '';
    const message = entry.message || '';
    
    // Handle MCP tool calls: mcp__server__tool_name or mcp_server__tool_name
    if (type.startsWith('mcp__') || type.startsWith('mcp_')) {
        // Extract just the tool name (last part after double underscore)
        const parts = type.split('__');
        let toolName = type;
        if (parts.length >= 3) {
            // mcp__dotbot__task_mark_done -> task_mark_done
            toolName = parts.slice(2).join('_');
        } else if (parts.length === 2) {
            // mcp__tool_name -> tool_name
            toolName = parts[1];
        }
        // Show "Tool" as type, tool name (+ message if any) as message
        const displayMessage = message ? `${toolName}: ${message}` : toolName;
        return { displayType: 'Tool', displayMessage };
    }
    
    return { displayType: type, displayMessage: message };
}

/**
 * Show a themed toast notification
 * @param {string} message - Message to display
 * @param {string} type - Toast type: 'error', 'success', 'warning', 'info'
 * @param {number} duration - Auto-dismiss time in ms (default 5000, 0 to persist)
 */
function showToast(message, type = 'info', duration = 5000) {
    const container = document.getElementById('toast-container');
    if (!container) return;

    const icons = { error: '!', success: '+', warning: '!', info: 'i' };

    const toast = document.createElement('div');
    toast.className = 'toast';
    toast.dataset.type = type;
    toast.innerHTML = `
        <span class="toast-icon">[${icons[type] || 'i'}]</span>
        <span class="toast-message">${escapeHtml(message)}</span>
        <button class="toast-close" title="Dismiss">&times;</button>
    `;

    const dismiss = () => {
        toast.classList.add('dismissing');
        toast.addEventListener('transitionend', () => toast.remove(), { once: true });
    };

    toast.querySelector('.toast-close').addEventListener('click', dismiss);

    container.appendChild(toast);
    // Trigger reflow then animate in
    requestAnimationFrame(() => toast.classList.add('visible'));

    if (duration > 0) {
        setTimeout(dismiss, duration);
    }
}

/**
 * Format duration between two ISO date strings
 * @param {string} startIso - Start ISO date string
 * @param {string} endIso - End ISO date string
 * @returns {string} Formatted duration like "2h 15m" or "1d 4h"
 */
function formatDuration(startIso, endIso) {
    if (!startIso || !endIso) return '';
    try {
        const start = new Date(startIso);
        const end = new Date(endIso);
        const diffMs = end - start;
        if (diffMs < 0) return '';

        const mins = Math.floor(diffMs / 60000);
        const hours = Math.floor(mins / 60);
        const days = Math.floor(hours / 24);

        if (days > 0) {
            const remainingHours = hours % 24;
            return remainingHours > 0 ? `${days}d ${remainingHours}h` : `${days}d`;
        }
        if (hours > 0) {
            const remainingMins = mins % 60;
            return remainingMins > 0 ? `${hours}h ${remainingMins}min` : `${hours}h`;
        }
        return `${mins}min`;
    } catch (e) {
        return '';
    }
}
