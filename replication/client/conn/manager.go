/*
  Copyright 2019 Nextdoor.com, Inc.

  Licensed under the Apache License, Version 2.0 (the "License");
  you may not use this file except in compliance with the License.
  You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software
  distributed under the License is distributed on an "AS IS" BASIS,
  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
  See the License for the specific language governing permissions and
  limitations under the License.
 */

package conn

import (
	"github.com/cenkalti/backoff"
	"github.com/jackc/pgx"
	"github.com/sirupsen/logrus"
	"os"
	"time"
)

var (
	logger              = logrus.New()
	log                 = logger.WithField("package", "conn")
	logProgressInterval = int64(30 * time.Second)
)

func init() {
	logger.SetOutput(os.Stdout)
	logger.SetLevel(logrus.InfoLevel)
}

// Manager here allows us to wrap our postgres connection for connection refreshes and ease of testing.
type Manager struct {
	sourceConfig    pgx.ConnConfig
	conn            Conn
	replicationSlot string
}

// NewManager simply returns a new Manager with the provided configuration.
func NewManager(sourceConfig pgx.ConnConfig, replicationSlot string) ManagerInterface {
	return &Manager{sourceConfig: sourceConfig,
		conn:            nil,
		replicationSlot: replicationSlot}
}

// GetConn idempotently returns an instance of a connection. It will make sure to re-connect if
// it is expired. This connection will have replication automatically started on it.
func (m *Manager) GetConn() (Conn, error) {
	// Create a new connection
	if m.conn == nil || !m.conn.IsAlive() {

		// Get a new connection
		conn, err := GetRawConn(m.sourceConfig)

		if err != nil {
			return nil, err
		}

		// Start replication on the connection
		err = conn.StartReplication(m.replicationSlot, 0, -1)

		if err != nil {
			return nil, err
		}

		m.conn = conn
	}

	return m.conn, nil
}

// Close idempotently closes a connection.
func (m *Manager) Close() {
	if m.conn == nil {
		return
	}

	m.conn.Close()
	m.conn = nil
}

// GetRawConn wraps pgx.ReplicationConnect with a retry loop. It returns a
// new replication connection without starting replication.
func GetRawConn(sourceConfig pgx.ConnConfig) (Conn, error) {
	var conn *pgx.ReplicationConn
	var err error

	retryPolicy := &backoff.ExponentialBackOff{
		InitialInterval:     backoff.DefaultInitialInterval,
		RandomizationFactor: backoff.DefaultRandomizationFactor,
		Multiplier:          backoff.DefaultMultiplier,
		MaxInterval:         backoff.DefaultMaxInterval,
		MaxElapsedTime:      time.Second * 20,
		Clock:               backoff.SystemClock,
	}

	operation := func() error {
		log.Infof("Attempting to create a connection to %s on %d", sourceConfig.Host,
			sourceConfig.Port)

		conn, err = pgx.ReplicationConnect(sourceConfig)
		return err
	}

	err = backoff.Retry(operation, retryPolicy)
	if err != nil {
		// Handle error.
		return nil, err
	}

	return conn, err
}
