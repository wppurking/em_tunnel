require "eventmachine"
require "pp"

class LocalConn < EM::Connection
  attr_accessor :proxy

  def initialize(*args)
    @proxy = args[0]
  end

  def receive_data(data)
    @proxy.send_data(data) if not data.empty?
  end

  def undind
    close_connection_after_writing
  end
end

module Local
  def post_init
    @data = ''
    @f = Fiber.new do
      say_hello
      loop { establish_sock5 }
    end
  end

  def receive_data(data)
    if @data
      @data << data
      if @f.resume
        @data = nil
        @f = nil
        close_connection
      end
    else
      @conn.send_data(data)
    end
  end

  # 为 sock 5 协议建立链接后的 say hello
  def say_hello
    ##pp @data.b
    wait 2
    ver, nmethods = @data.unpack("C2") 

    #         sock5 拒绝  (不是 sock5 协议, 拒绝链接)
    send_data "\x05\xFF" if ver != 5 

    # 这里不管 nmethods 提交的是需要什么验证, 先直接返回验证成功试试; 这次请求完毕, 清理 @data
    #TODO 这里需要考虑, 如果 @data 中已经存在的数据大于 2 bytes 时, 多余的数据不应该被清理掉.
    @data = ''
    send_data "\x05\x00"
  end

  # 解析 sock 5 协议, 并且建立代理的链接, 以供后续的数据传输使用
  def establish_sock5
    # 等待建立了 sock 5 链接后, 发送过来的消息
    wait 5

    #pp @data.b
    # 解析 sock 5 的请求(这里先解析前 5 个bit)
    # ver 版本号: 5 -> 这里为 sock 5
    # cmd 操作命令: 1. CONNECT; 2. BIND; 3. UDP ASSOCIATE
    # rsv: 保留位
    # atyp 地址类型: 1. IPv4; 3. Domain Name; 4. IPv6
    ver, cmd, rsv, atyp, domain_len = @data.unpack("C5")

    case atyp
    when 1, 4
      reject
    when 3
      host_and_port_bytes = @data[5..-1]
      wait 5 + domain_len + 2 # 等待 5 bit + domain_len 长度的 bit + 端口 2bit
      host = host_and_port_bytes.byteslice 0, domain_len
      port = host_and_port_bytes.byteslice(domain_len, host_and_port_bytes.size).unpack("S>").first
      pp "Proxy: #{host}:#{port}"
    else
      reject
    end

    case cmd
    when 1
      # 这里返回与 sock5 握手成功, 接下来可以进行详细数据传输了. 下面就可以将数据一点一点传入给 server 了
      ok

      @conn = EM.connect host, port, LocalConn, self

      # 进入另外一条逻辑
      @data = nil
      # 到这里, 与 sock 5 的握手已经完成, 不再需要借助 Fiber 获取完整数据去做 sock 5 协议解析了, 剩下的交给 receive_data
      # 将数据全部转发出去就可以了; Fibre 从这个点开始 yield 停止运行, 直到最后 close_connection 资源被 GC 回收
      Fiber.yield
    when 2, 3
      reject
    else
      reject
    end
  end

  # 等待接收到合适大小的数据. 如果 Fiber 没有收取到对应大小字节的数据, 则 yield 让其继续读取数据
  def wait n
    Fiber.yield if not @data.b.size >= n
  end

  def ok
    send_data "\x05\x00\x00\x01" << "\x00\x00\x00\x00" << "\x00\x00"
  end

  # 拒绝. 先不管, 全部返回 "general SOCKS server failure"
  def reject
    send_data "\x05\x01\x00\x01" << "\x00\x00\x00\x00" << "\x00\x00"
    #           ver rsp  rsv atyp     ip                  port
    # 让 Fiber 退回到 receive_data 中, 并且通过 yield true 返回并且清理数据与关闭链接
    Fiber.yield true
  end
end


EM.run do
  host = "127.0.0.1"
  port = 7070
  puts "Listen #{host}:#{port}"
  EM.start_server host, port, Local
end
