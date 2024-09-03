# frozen_string_literal: true

require_relative 'helper'

class IOURingBaseTest < Minitest::Test
  attr_accessor :ring
  
  def setup
    @ring = IOU::Ring.new
  end

  def teardown
    ring.close
  end
end

class IOURingTest < IOURingBaseTest
  def test_close
    ring2 = IOU::Ring.new
    refute ring2.closed?

    ring2.close
    assert ring2.closed?
  end
end

class PrepTimeoutTest < IOURingBaseTest
  def test_prep_timeout
    period = 0.03

    t0 = monotonic_clock
    id = ring.prep_timeout(period: period)
    assert_equal 1, id

    ring.submit
    c = ring.wait_for_completion
    elapsed = monotonic_clock - t0
    assert_in_range period..(period + 0.02), elapsed

    assert_kind_of Hash, c
    assert_equal id, c[:id]
    assert_equal :timeout, c[:op]
    assert_equal period, c[:period]
    assert_equal -Errno::ETIME::Errno, c[:result]
  end

  def test_prep_timeout_invalid_args
    assert_raises(ArgumentError) { ring.prep_timeout() }
    assert_raises(ArgumentError) { ring.prep_timeout(foo: 1) }
    assert_raises(ArgumentError) { ring.prep_timeout(1) }
  end
end

class PrepCancelTest < IOURingBaseTest
  def test_prep_cancel
    period = 15
    timeout_id = ring.prep_timeout(period: period)
    assert_equal 1, timeout_id

    cancel_id = ring.prep_cancel(timeout_id)
    assert_equal 2, cancel_id

    ring.submit
    c = ring.wait_for_completion
    assert_equal cancel_id, c[:id]
    assert_equal 0, c[:result]

    c = ring.wait_for_completion
    assert_equal timeout_id, c[:id]
    assert_equal :timeout, c[:op]
    assert_equal period, c[:period]
    assert_equal -Errno::ECANCELED::Errno, c[:result]
  end

  def test_prep_cancel_kw
    period = 15
    timeout_id = ring.prep_timeout(period: period)
    assert_equal 1, timeout_id

    cancel_id = ring.prep_cancel(id: timeout_id)
    assert_equal 2, cancel_id

    ring.submit
    c = ring.wait_for_completion
    assert_equal cancel_id, c[:id]
    assert_equal 0, c[:result]

    c = ring.wait_for_completion
    assert_equal timeout_id, c[:id]
    assert_equal :timeout, c[:op]
    assert_equal period, c[:period]
    assert_equal -Errno::ECANCELED::Errno, c[:result]
  end

  def test_prep_cancel_invalid_args
    assert_raises(ArgumentError) { ring.prep_cancel() }
    assert_raises(ArgumentError) { ring.prep_cancel('foo') }
    assert_raises(ArgumentError) { ring.prep_cancel({}) }
    assert_raises(TypeError) { ring.prep_cancel(id: 'bar') }
  end

  def test_prep_cancel_invalid_id
    cancel_id = ring.prep_cancel(id: 42)
    assert_equal 1, cancel_id

    ring.submit
    c = ring.wait_for_completion
    assert_equal cancel_id, c[:id]
    assert_equal -Errno::ENOENT::Errno, c[:result]
  end
end

class PrepWriteTest < IOURingBaseTest
  def test_prep_write
    r, w = IO.pipe
    s = 'foobar'

    id = ring.prep_write(fd: w.fileno, buffer: s)
    assert_equal 1, id

    ring.submit
    c = ring.wait_for_completion

    assert_kind_of Hash, c
    assert_equal id, c[:id]
    assert_equal :write, c[:op]
    assert_equal w.fileno, c[:fd]
    assert_equal s.bytesize, c[:result]

    w.close
    assert_equal s, r.read
  end

  def test_prep_write_with_len
    r, w = IO.pipe
    s = 'foobar'

    id = ring.prep_write(fd: w.fileno, buffer: s, len: 3)
    assert_equal 1, id

    ring.submit
    c = ring.wait_for_completion

    assert_kind_of Hash, c
    assert_equal id, c[:id]
    assert_equal :write, c[:op]
    assert_equal w.fileno, c[:fd]
    assert_equal 3, c[:result]

    w.close
    assert_equal s[0..2], r.read
  end

  def test_prep_write_invalid_args
    assert_raises(ArgumentError) { ring.prep_write() }
    assert_raises(ArgumentError) { ring.prep_write(foo: 1) }
    assert_raises(ArgumentError) { ring.prep_write(fd: 'bar') }
    assert_raises(ArgumentError) { ring.prep_write({}) }
  end

  def test_prep_write_invalid_fd
    r, w = IO.pipe
    s = 'foobar'

    id = ring.prep_write(fd: r.fileno, buffer: s)
    assert_equal 1, id

    ring.submit
    c = ring.wait_for_completion

    assert_kind_of Hash, c
    assert_equal id, c[:id]
    assert_equal :write, c[:op]
    assert_equal r.fileno, c[:fd]
    assert_equal -Errno::EBADF::Errno, c[:result]
  end
end

class PrepNopTest < IOURingBaseTest
  def test_prep_nop
    id = ring.prep_nop
    assert_equal 1, id

    ring.submit
    c = ring.wait_for_completion

    assert_kind_of Hash, c
    assert_equal id, c[:id]
    assert_nil c[:op]
    assert_equal 0, c[:result]
  end
end

class ProcessCompletionsTest < IOURingBaseTest
  def test_process_completions_no_wait
    ret = ring.process_completions
    assert_equal 0, ret

    (1..3).each do |i|
      id = ring.prep_nop
      assert_equal i, id
    end

    ring.submit
    sleep 0.001

    ret = ring.process_completions
    assert_equal 3, ret
  end

  def test_process_completions_wait
    (1..3).each do |i|
      id = ring.prep_nop
      assert_equal i, id
    end

    ring.submit
    ret = ring.process_completions(true)
    assert_equal 3, ret
  end

  def test_process_completions_with_block
    r, w = IO.pipe

    id1 = ring.prep_write(fd: w.fileno, buffer: 'foo')
    id2 = ring.prep_write(fd: w.fileno, buffer: 'bar')
    id3 = ring.prep_write(fd: w.fileno, buffer: 'baz')
    ring.submit
    sleep 0.01

    completions = []

    ret = ring.process_completions do |c|
      completions << c
    end

    assert_equal 3, ret
    assert_equal 3, completions.size
    assert_equal [1, 2, 3], completions.map { _1[:id] }
    assert_equal [:write], completions.map { _1[:op] }.uniq
    assert_equal 9, completions.inject(0) { |t, c| t + c[:result] }

    w.close
    assert_equal 'foobarbaz', r.read
  end

  def test_process_completions_op_with_block
    cc = []

    id1 = ring.prep_timeout(period: 0.01) { cc << 1 }
    id2 = ring.prep_timeout(period: 0.02) { cc << 2 }
    ring.submit

    ret = ring.process_completions
    assert_equal 0, ret
    assert_equal [], cc

    sleep 0.02
    ret = ring.process_completions(true)

    assert_equal 2, ret
    assert_equal [1, 2], cc
  end

  def test_process_completions_op_with_block_no_submit
    cc = []

    id1 = ring.prep_timeout(period: 0.01) { cc << 1 }
    id2 = ring.prep_timeout(period: 0.02) { cc << 2 }

    ret = ring.process_completions
    assert_equal 0, ret
    assert_equal [], cc

    sleep 0.02
    ret = ring.process_completions(true)
    assert_equal 2, ret
    assert_equal [1, 2], cc
  end
end
