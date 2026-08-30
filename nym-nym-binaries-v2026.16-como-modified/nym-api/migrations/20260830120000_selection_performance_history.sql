CREATE TABLE selection_performance_history
(
    node_id     INTEGER NOT NULL,
    epoch_id    INTEGER NOT NULL,
    performance REAL    NOT NULL CHECK (
        performance >= 0.0 AND performance <= 1.0
    ),
    measured_at INTEGER NOT NULL,

    PRIMARY KEY (node_id, epoch_id)
);

CREATE INDEX selection_performance_history_epoch_idx
    ON selection_performance_history (epoch_id, node_id);
