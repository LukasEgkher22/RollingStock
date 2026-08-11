import matplotlib.pyplot as plt
import matplotlib.ticker as ticker
import numpy as np
from matplotlib.patches import Patch

# ===========================================================================
# CONFIGURATION & STYLING - UPDATED FONT SIZES
# ===========================================================================
FS_TITLE = 20    # Main titles
FS_LABEL = 18    # Axis labels (Time, Station names)
FS_TICK = 14     # HH:MM and Y-axis tick values
FS_LEGEND = 16   # Legend text and legend titles
FS_ANNOT = 12    # Text on the arrows (Compositions)

TRAIN_COLORS = {
    "10": "#F5A623", "100": "#7B68EE", "20": "#4CAF50", "200": "#E57373"
}

UNIT_COLORS = {
    "ICA": "#29B6F6", # Blue
    "ERF": "#FFA726"  # Orange
}

def format_minutes(total_minutes, _=None):
    h, m = divmod(int(total_minutes) % 1440, 60)
    return f"{h:02d}:{m:02d}"

# ===========================================================================
# DATA & PARSING
# ===========================================================================
def get_example_data():
    stations = ["AR/86", "VJ/86", "FA/86", "CPH/86"]
    trips = [
        {"TrainId": "10", "From": "AR/86", "To": "VJ/86", "Dep": 320, "Arr": 364, "Dem": 153, "Comp": "2xICA"},
        {"TrainId": "10", "From": "VJ/86", "To": "FA/86", "Dep": 366, "Arr": 381, "Dem": 203, "Comp": "2xICA"},
        {"TrainId": "10", "From": "FA/86", "To": "CPH/86", "Dep": 387, "Arr": 512, "Dem": 614, "Comp": "2xICA, 2xERF"},
        {"TrainId": "100", "From": "CPH/86", "To": "FA/86", "Dep": 540, "Arr": 650, "Dem": 141, "Comp": "1xERF"},
        {"TrainId": "20", "From": "FA/86", "To": "VJ/86", "Dep": 400, "Arr": 450, "Dem": 80, "Comp": "1xICA"},
        {"TrainId": "20", "From": "VJ/86", "To": "AR/86", "Dep": 480, "Arr": 530, "Dem": 50, "Comp": "1xICA"},
    ]
    initial_inv = {
        "AR/86":  {"ICA": 2, "ERF": 0},
        "VJ/86":  {"ICA": 0, "ERF": 0},
        "FA/86":  {"ICA": 1, "ERF": 2},
        "CPH/86": {"ICA": 0, "ERF": 0},
    }
    return stations, trips, initial_inv

def parse_comp(comp_str):
    parts = comp_str.split(",")
    res = {"ICA": 0, "ERF": 0}
    for p in parts:
        p = p.strip()
        if 'x' in p:
            count, kind = p.split('x')
            res[kind.strip()] = int(count)
    return res

# ===========================================================================
# PLOTTING
# ===========================================================================
def build_diagram():
    stations, trips, initial_inv = get_example_data()
    
    min_t = min(t["Dep"] for t in trips) - 60
    max_t = max(t["Arr"] for t in trips) + 60
    
    st_events = {s: [] for s in stations}
    for t in trips:
        counts = parse_comp(t["Comp"])
        st_events[t["From"]].append((t["Dep"], -counts["ICA"], -counts["ERF"]))
        st_events[t["To"]].append((t["Arr"], counts["ICA"], counts["ERF"]))

    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(14, 14), 
                                   gridspec_kw={'height_ratios': [1, 1.5], 'hspace': 0.4})

    # --- TOP PLOT: TIME-SPACE ---
    y_map = {stat: i for i, stat in enumerate(stations)}
    ax1.set_yticks(range(len(stations)))
    ax1.set_yticklabels(stations, fontweight='bold', fontsize=FS_LABEL)
    
    for t in trips:
        color = TRAIN_COLORS.get(t["TrainId"], "#333333")
        y0, y1 = y_map[t["From"]], y_map[t["To"]]
        t0, t1 = t["Dep"], t["Arr"]
        
        ax1.plot([t0, t1], [y0, y1], color=color, alpha=0.2, lw=1)
        ax1.annotate("", xy=(t1, y1), xytext=(t0, y0),
                     arrowprops=dict(arrowstyle="->", color=color, lw=2.5, mutation_scale=15))
        
        mid_t, mid_y = (t0 + t1) / 2, (y0 + y1) / 2
        ax1.text(mid_t, mid_y + 0.05, f"{t['Comp']}", color=color, 
                 fontsize=FS_ANNOT, ha='center', fontweight='bold', 
                 bbox=dict(facecolor='white', alpha=0.8, edgecolor='none', pad=1))

    ax1.set_title("Train Movements", fontsize=FS_TITLE, pad=15)
    ax1.set_xlim(min_t, max_t)
    ax1.xaxis.set_major_formatter(ticker.FuncFormatter(format_minutes))
    ax1.tick_params(axis='x', labelsize=FS_TICK)
    ax1.grid(True, linestyle=':', alpha=0.5)

    # --- BOTTOM PLOT: STACKED INVENTORY ---
    offset_step = 8 
    
    for i, stat in enumerate(stations):
        base_y = i * offset_step
        events = sorted(st_events[stat])
        
        for h in range(1, 6):
            ax2.axhline(base_y + h, color='gray', linestyle='--', linewidth=0.5, alpha=0.3)
        
        times = [min_t]
        ica_levels = [initial_inv[stat]["ICA"]]
        erf_levels = [initial_inv[stat]["ERF"]]
        c_ica, c_erf = initial_inv[stat]["ICA"], initial_inv[stat]["ERF"]
        
        for etime, dica, derf in events:
            times.extend([etime, etime])
            ica_levels.extend([c_ica, c_ica + dica])
            erf_levels.extend([c_erf, c_erf + derf])
            c_ica += dica
            c_erf += derf
            
        times.append(max_t)
        ica_levels.append(c_ica)
        erf_levels.append(c_erf)
        
        times = np.array(times)
        ica_levels = np.array(ica_levels)
        erf_levels = np.array(erf_levels)
        
        ax2.fill_between(times, base_y, base_y + erf_levels, 
                         step='post', color=UNIT_COLORS["ERF"], 
                         alpha=0.9, edgecolor='none', linewidth=0,
                         label="ERF" if i==0 else "")
        
        ax2.fill_between(times, base_y + erf_levels, base_y + erf_levels + ica_levels, 
                         step='post', color=UNIT_COLORS["ICA"], 
                         alpha=0.9, edgecolor='none', linewidth=0,
                         label="ICA" if i==0 else "")
        
        ax2.axhline(base_y, color='black', lw=1.5, alpha=0.7)
        # Station text labels on the left
        ax2.text(min_t - 15, base_y + 0.2, stat, fontweight='bold', 
                 ha='right', va='bottom', fontsize=FS_LABEL)

    ax2.set_title("Station Inventory Over Time", fontsize=FS_TITLE, pad=15)
    ax2.set_xlim(min_t, max_t)
    ax2.set_xlabel("Time (HH:MM)", fontsize=FS_LABEL, labelpad=10)
    ax2.set_yticks([]) 
    ax2.xaxis.set_major_formatter(ticker.FuncFormatter(format_minutes))
    ax2.tick_params(axis='x', labelsize=FS_TICK)
    
    # Legends with updated font sizes
    unit_handles = [Patch(facecolor=UNIT_COLORS["ICA"], label='ICA'),
                    Patch(facecolor=UNIT_COLORS["ERF"], label='ERF')]
    ax2.legend(handles=unit_handles, loc='upper right', title="Units", 
               fontsize=FS_LEGEND, title_fontsize=FS_LEGEND)

    active_trains = sorted(list(set(t["TrainId"] for t in trips)))
    train_handles = [Patch(facecolor=TRAIN_COLORS[tid], label=f"{tid}") for tid in active_trains]
    ax1.legend(handles=train_handles, title="Train IDs", loc="upper right", 
               fontsize=FS_LEGEND, title_fontsize=FS_LEGEND)

    plt.tight_layout()
    plt.show()

if __name__ == "__main__":
    build_diagram()